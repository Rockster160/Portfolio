require "rails_helper"

RSpec.describe FeatureBuilder do
  let(:user)   { User.me }
  let(:thread) { user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current) }
  let(:build)  {
    allow(FeatureBuildStartWorker).to receive(:perform_async)
    message = described_class.start!(user: user, conversation: thread, text: "add dark mode")
    FeatureBuild.find(message.metadata["feature_build_id"])
  }
  let(:branch) { "feature-builder/#{build.id}-dark-mode" }

  before { allow(FeatureBuilderFeedbackWorker).to receive(:perform_in) }

  def pull_request(ref: branch, number: 42, merged: false)
    { "number" => number, "head" => { "ref" => ref }, "merged" => merged }
  end

  describe "the thread it was asked from" do
    it "hears one message, rewritten with the session's link once the Mini has it" do
      described_class.update_from_mini!(build, {
        "status" => "running",
        "branch" => branch,
        "rc_url" => "https://claude.ai/code/session_abc",
      })

      expect(thread.byte_messages.count).to eq(1)
      expect(thread.byte_messages.last.body).to include(
        "Building **dark mode**",
        "(https://claude.ai/code/session_abc)",
      )
    end

    it "is sent the PR once, when the Mini first reports it" do
      allow(Buddy::CompanionDelivery).to receive(:deliver_plain).and_call_original
      pr = { "pr_number" => 42, "pr_url" => "https://github.com/Rockster160/Portfolio/pull/42" }

      described_class.update_from_mini!(build, pr)
      described_class.update_from_mini!(build, pr)

      expect(Buddy::CompanionDelivery).to have_received(:deliver_plain).once
      expect(thread.byte_messages.last.body).to include(
        "[PR #42](https://github.com/Rockster160/Portfolio/pull/42)",
      )
    end

    it "says why when the build couldn't start" do
      described_class.update_from_mini!(build, { "status" => "failed", "error" => "git fetch failed" })

      expect(thread.byte_messages.last.body).to include("Couldn't start", "git fetch failed")
    end
  end

  describe ".valid_signature?" do
    before { DataStorage[described_class::SECRET_KEY] = "shh" }

    it "takes GitHub's signature over the exact body" do
      signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "shh", "{}")}"

      expect(described_class.valid_signature?("{}", signature)).to be(true)
      expect(described_class.valid_signature?("{ }", signature)).to be(false)
    end

    it "refuses everything when no secret has been set" do
      DataStorage[described_class::SECRET_KEY] = nil
      signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "", "{}")}"

      expect(described_class.valid_signature?("{}", signature)).to be(false)
    end
  end

  describe ".github!" do
    def owner_comment(body, number: 42)
      described_class.github!(:issue_comment, {
        "action"  => "created",
        "issue"   => { "number" => number, "pull_request" => {} },
        "comment" => { "user" => { "login" => "Rockster160" }, "body" => body },
      })
    end

    it "holds the owner's line comment for the session" do
      outcome = described_class.github!(:pull_request_review_comment, {
        "action"       => "created",
        "pull_request" => pull_request,
        "comment"      => {
          "id"   => 7,
          "user" => { "login" => "Rockster160" },
          "path" => "app/models/user.rb",
          "line" => 12,
          "body" => "Use a symbol here",
        },
      })

      expect(outcome).to eq(:queued)
      expect(build.reload.feedback.last["text"]).to include("app/models/user.rb:12", "Use a symbol here")
      expect(FeatureBuilderFeedbackWorker).to have_received(:perform_in).with(anything, build.id)
    end

    it "finds a PR comment's build by its PR number, and says nothing in the thread" do
      build.update!(pr_number: 42)

      expect { owner_comment("One more thing") }.not_to(change { thread.byte_messages.count })
      expect(build.reload.feedback.last["text"]).to include("One more thing")
    end

    it "ignores ByteSlime answering on its own PR" do
      build.update!(pr_number: 42)

      outcome = described_class.github!(:issue_comment, {
        "action"  => "created",
        "issue"   => { "number" => 42, "pull_request" => {} },
        "comment" => { "user" => { "login" => "ByteSlime" }, "body" => "Done." },
      })

      expect(outcome).to eq(:ignored)
      expect(build.reload.feedback).to be_empty
    end

    it "leaves PRs that aren't a build's alone" do
      outcome = described_class.github!(:pull_request_review, {
        "action"       => "submitted",
        "pull_request" => pull_request(ref: "some-feature", number: 9),
        "review"       => { "user" => { "login" => "Rockster160" }, "state" => "commented", "body" => "Hm" },
      })

      expect(outcome).to eq(:unknown)
    end

    it "passes a review on only when it has words or asks for changes" do
      review = ->(state, body) {
        described_class.github!(:pull_request_review, {
          "action"       => "submitted",
          "pull_request" => pull_request,
          "review"       => { "user" => { "login" => "Rockster160" }, "state" => state, "body" => body },
        })
      }

      expect(review.call("commented", "")).to eq(:ignored)
      expect(review.call("changes_requested", "")).to eq(:queued)
      expect(build.reload.feedback.last["text"]).to include("Changes requested")
    end

    it "ends the build on the Mini when its PR is merged" do
      finish = stub_request(:post, %r{/byte/builder\z}).with(
        body: hash_including("action" => "finish", "build_id" => build.id, "merged" => true),
      ).to_return(status: 200, body: "{}")

      outcome = described_class.github!(:pull_request, {
        "action"       => "closed",
        "pull_request" => pull_request(merged: true),
      })

      expect(outcome).to eq(:finished)
      expect(finish).to have_been_requested
      expect(build.reload).to be_status_finished
    end

    it "keeps the build open when the Mini can't be told" do
      outcome = described_class.github!(:pull_request, {
        "action"       => "closed",
        "pull_request" => pull_request,
      })

      expect(outcome).to eq(:mini_unreachable)
      expect(build.reload).not_to be_status_finished
    end
  end

  describe ".gather" do
    def comment(text, at:)
      travel_to(at) { described_class.feedback!(build, text) }
    end

    it "puts everything waiting into one prompt" do
      comment("First", at: 2.minutes.ago)
      comment("Second", at: 1.minute.ago)

      expect(described_class.gather(build.reload)).to include("- First", "- Second")
    end

    it "waits while the newest comment is still inside its quiet window" do
      comment("Just now", at: Time.current)

      expect(described_class.gather(build.reload)).to be_nil
    end
  end

  describe "the Mini's sessions" do
    let(:audit) { user.byte_conversations.create!(name: ByteDailyAudit::NAME, mode: :claude) }

    def chip
      BackgroundProcess.live_find(user, described_class::CHIP_KEY)
    end

    def report(*sessions)
      described_class.report_sessions!(machine: :mini, sessions: sessions)
    end

    it "says what one working session is doing" do
      report({ "conversation_id" => audit.id, "kind" => "turn", "working" => true })
      expect(chip.name).to eq("Auditing…")

      report({ "build_id" => 1, "kind" => "builder", "working" => true })
      expect(chip.name).to eq("Building…")
    end

    it "counts several, and names them when they're all builders" do
      report(
        { "build_id" => 1, "kind" => "builder", "working" => true },
        { "build_id" => 2, "kind" => "builder", "working" => true },
      )
      expect(chip.name).to eq("2x Builders running")

      report(
        { "build_id" => 1, "kind" => "builder", "working" => true },
        { "conversation_id" => audit.id, "kind" => "turn", "working" => true },
      )
      expect(chip.name).to eq("2x Claude running")
    end

    it "leaves a build that's waiting on an answer off the chip" do
      report({ "build_id" => 1, "kind" => "builder", "working" => false })

      expect(chip).to be_nil
      expect(described_class.sessions.length).to eq(1)
    end

    it "clears the chip when nothing is left" do
      report({ "conversation_id" => audit.id, "kind" => "turn", "working" => true })
      report

      expect(chip).to be_nil
    end

    it "stops believing a report the Mini never followed up" do
      travel_to(10.minutes.ago) {
        report({ "conversation_id" => audit.id, "kind" => "turn", "working" => true })
      }

      expect(described_class.sessions).to be_empty
    end
  end
end
