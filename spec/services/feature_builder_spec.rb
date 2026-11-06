require "rails_helper"

RSpec.describe FeatureBuilder do
  let(:user)    { User.me }
  let(:builder) { user.byte_conversations.create!(mode: :builder, last_message_at: Time.current) }
  let(:branch)  { "feature-builder/#{builder.id}-dark-mode" }

  before { allow(FeatureBuilderFeedbackWorker).to receive(:perform_in) }

  def pull_request(ref: branch, number: 42, merged: false)
    { "number" => number, "head" => { "ref" => ref }, "merged" => merged }
  end

  def feedback_bodies(conversation=builder)
    conversation.byte_messages.where("metadata->>'pr_feedback' = 'true'").pluck(:body)
  end

  describe "a new thread" do
    it "opens a builder thread by saying what it does" do
      described_class.intro!(builder)

      expect(builder.byte_messages.last.body).to include("Tell me what you want built")
    end

    it "says nothing in any other kind of thread" do
      claude = user.byte_conversations.create!(mode: :claude, last_message_at: Time.current)

      expect { described_class.intro!(claude) }.not_to change(ByteMessage, :count)
    end
  end

  describe "a builder thread" do
    it "runs on the Mini and is named for what it is" do
      expect(builder).to be_on_mini
      expect(builder.display_name).to eq("Feature Builder")
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
    it "shows the owner's line comment in the thread and queues it for the session" do
      outcome = described_class.github!(:pull_request_review_comment, {
        "action"       => "created",
        "pull_request" => pull_request,
        "comment"      => {
          "id"       => 7,
          "user"     => { "login" => "Rockster160" },
          "path"     => "app/models/user.rb",
          "line"     => 12,
          "body"     => "Use a symbol here",
          "html_url" => "https://github.com/x",
        },
      })

      expect(outcome).to eq(:queued)
      expect(feedback_bodies.last).to include("app/models/user.rb:12", "Use a symbol here")
      expect(FeatureBuilderFeedbackWorker).to have_received(:perform_in).with(anything, builder.id)
    end

    it "ignores ByteSlime answering on its own PR" do
      outcome = described_class.github!(:issue_comment, {
        "action"  => "created",
        "issue"   => { "number" => 42, "pull_request" => {} },
        "comment" => { "user" => { "login" => "ByteSlime" }, "body" => "Done." },
      })

      expect(outcome).to eq(:ignored)
      expect(feedback_bodies).to be_empty
    end

    it "finds a PR comment's thread by its PR number" do
      builder.update!(metadata: { "builder" => { "pr_number" => 42 } })

      described_class.github!(:issue_comment, {
        "action"  => "created",
        "issue"   => { "number" => 42, "pull_request" => {} },
        "comment" => { "user" => { "login" => "Rockster160" }, "body" => "Looks good, one more thing" },
      })

      expect(feedback_bodies.last).to include("one more thing")
    end

    it "leaves PRs that aren't a builder's alone" do
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
      expect(feedback_bodies.last).to include("Changes requested")
    end

    it "ends the session on the Mini when the PR is merged" do
      finish = stub_request(:post, %r{/byte/builder\z}).with(
        body: hash_including("action" => "finish", "conversation_id" => builder.id, "merged" => true),
      ).to_return(status: 200, body: "{}")

      outcome = described_class.github!(:pull_request, {
        "action"       => "closed",
        "pull_request" => pull_request(merged: true),
      })

      expect(outcome).to eq(:finished)
      expect(finish).to have_been_requested
    end

    it "says so in the thread when the Mini can't be told" do
      outcome = described_class.github!(:pull_request, {
        "action"       => "closed",
        "pull_request" => pull_request,
      })

      expect(outcome).to eq(:mini_unreachable)
      expect(builder.byte_messages.last.body).to include("closed", "didn't answer")
    end
  end

  describe ".gather!" do
    def comment(text, at:)
      travel_to(at) { described_class.feedback_for!(builder, text, nil) }
    end

    it "hands over everything waiting as one prompt, once" do
      comment("First", at: 2.minutes.ago)
      comment("Second", at: 1.minute.ago)

      prompt = described_class.gather!(builder)

      expect(prompt).to include("- First", "- Second")
      expect(described_class.gather!(builder)).to be_nil
    end

    it "waits while the newest comment is still inside its quiet window" do
      comment("Just now", at: Time.current)

      expect(described_class.gather!(builder)).to be_nil
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

      report({ "conversation_id" => builder.id, "kind" => "builder", "working" => true })
      expect(chip.name).to eq("Building…")
    end

    it "counts several, and names them when they're all builders" do
      other = user.byte_conversations.create!(mode: :builder)
      report(
        { "conversation_id" => builder.id, "kind" => "builder", "working" => true },
        { "conversation_id" => other.id, "kind" => "builder", "working" => true },
      )
      expect(chip.name).to eq("2x Builders running")

      report(
        { "conversation_id" => builder.id, "kind" => "builder", "working" => true },
        { "conversation_id" => audit.id, "kind" => "turn", "working" => true },
      )
      expect(chip.name).to eq("2x Claude running")
    end

    it "leaves a builder that's waiting on an answer off the chip" do
      report({ "conversation_id" => builder.id, "kind" => "builder", "working" => false })

      expect(chip).to be_nil
      expect(described_class.sessions.length).to eq(1)
    end

    it "clears the chip when nothing is left" do
      report({ "conversation_id" => audit.id, "kind" => "turn", "working" => true })
      report

      expect(chip).to be_nil
    end

    it "stops believing a report the Mini never followed up" do
      travel_to(10.minutes.ago) { report({ "conversation_id" => audit.id, "kind" => "turn", "working" => true }) }

      expect(described_class.sessions).to be_empty
    end
  end
end
