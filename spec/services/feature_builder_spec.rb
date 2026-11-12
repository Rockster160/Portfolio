require "rails_helper"

RSpec.describe FeatureBuilder do
  let(:user)   { User.me }
  let(:thread) { user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current) }
  let(:build)  {
    allow(FeatureBuildStartWorker).to receive(:perform_async)
    message = described_class.start!(user: user, conversation: thread, text: "add dark mode")
    FeatureBuild.find(message.metadata["feature_build_id"])
  }
  let(:branch) { "byte/#{build.id}-dark-mode" }

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

    it "is sent the PR once, when the Mini first reports it, with the session's link" do
      allow(Buddy::CompanionDelivery).to receive(:deliver_plain).and_call_original
      build.update!(rc_url: "https://claude.ai/code/session_abc")
      pr = { "pr_number" => 42, "pr_url" => "https://github.com/Rockster160/Portfolio/pull/42" }

      described_class.update_from_mini!(build, pr)
      described_class.update_from_mini!(build, pr)

      expect(Buddy::CompanionDelivery).to have_received(:deliver_plain).once
      expect(thread.byte_messages.last.body).to include(
        "[PR #42](https://github.com/Rockster160/Portfolio/pull/42)",
        "[Open it in Claude](https://claude.ai/code/session_abc)",
      )
    end

    it "says why when the build couldn't start" do
      described_class.update_from_mini!(build, { "status" => "failed", "error" => "git fetch failed" })

      expect(thread.byte_messages.last.body).to include("Couldn't start", "git fetch failed")
    end

    it "links the Mini page until the session has a link of its own" do
      expect(build.byte_message.body).to include("Starting a Feature Builder", "/system/claude)")

      described_class.update_from_mini!(build, { "status" => "failed", "error" => "git fetch failed" })
      expect(thread.byte_messages.last.body).to include("/system/claude)")
    end
  end

  describe "a plan" do
    it "is recorded once, without a word in the thread" do
      allow(Buddy::CompanionDelivery).to receive(:deliver_plain).and_call_original
      build.update!(rc_url: "https://claude.ai/code/session_abc")

      described_class.update_from_mini!(build, { "planned_at" => Time.current.iso8601 })
      first = build.reload.planned_at
      travel(5.minutes) { described_class.update_from_mini!(build, { "planned_at" => Time.current.iso8601 }) }

      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_plain)
      expect(build.reload.planned_at).to eq(first)
      expect(thread.byte_messages.count).to eq(1)
    end

    it "moves a working build's chip from planning to building" do
      described_class.report_sessions!(machine: :mini, sessions: [
        { "build_id" => build.id, "kind" => "builder", "working" => true },
      ])
      chip = -> { BackgroundProcess.live_find(user, described_class::CHIP_KEY) }
      expect(chip.call.name).to eq("Planning…")

      described_class.update_from_mini!(build, { "planned_at" => Time.current.iso8601 })

      expect(chip.call.name).to eq("Building…")
    end
  end

  describe "a turn that ends waiting on the owner" do
    before { allow(Buddy::CompanionDelivery).to receive(:deliver_plain).and_call_original }

    it "pings the thread with the session's link each time" do
      build.update!(rc_url: "https://claude.ai/code/session_abc")

      described_class.update_from_mini!(build, { "waiting_at" => Time.current.iso8601 })
      described_class.update_from_mini!(build, { "waiting_at" => Time.current.iso8601 })

      expect(Buddy::CompanionDelivery).to have_received(:deliver_plain).twice.with(
        hash_including(push_title: "Waiting on you: dark mode"),
      )
      expect(thread.byte_messages.last.body).to include(
        "**dark mode** is waiting on you.",
        "[Open it in Claude](https://claude.ai/code/session_abc)",
      )
    end

    it "still pings when the turn that ended had posted a plan" do
      now = Time.current.iso8601
      described_class.update_from_mini!(build, { "planned_at" => now, "waiting_at" => now })

      expect(Buddy::CompanionDelivery).to have_received(:deliver_plain).once
      expect(thread.byte_messages.last.body).to include("is waiting on you")
    end

    it "says only the PR when the turn that ended opened it" do
      now = Time.current.iso8601
      described_class.update_from_mini!(build, {
        "pr_number"  => 42,
        "pr_url"     => "https://github.com/x/pull/42",
        "waiting_at" => now,
      })

      expect(Buddy::CompanionDelivery).to have_received(:deliver_plain).once
      expect(thread.byte_messages.last.body).to include("is ready for review")
    end

    it "says nothing for a build that's over" do
      build.update!(status: :finished)

      described_class.update_from_mini!(build, { "waiting_at" => Time.current.iso8601 })

      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_plain)
    end
  end

  describe "a question a build stops on" do
    before { allow(Buddy::CompanionDelivery).to receive(:deliver_plain).and_call_original }

    def deliver(text)
      stub_request(:post, %r{/byte/builder\z}).with(
        body: hash_including("action" => "message", "build_id" => build.id, "text" => text),
      ).to_return(status: 200, body: "{}")
    end

    it "is posted in full, saying a reply answers it" do
      described_class.update_from_mini!(build, {
        "waiting_at" => Time.current.iso8601,
        "question"   => "1. Dark by default?\n2. Follow the system setting?",
      })

      expect(thread.byte_messages.last.body).to include(
        "**dark mode** is asking:",
        "1. Dark by default?\n2. Follow the system setting?",
        "Reply to this to answer.",
      )
      expect(described_class.asking(user)).to eq([build])
    end

    it "goes to the session when a message about the build is replied to" do
      described_class.update_from_mini!(build, { "waiting_at" => Time.current.iso8601, "question" => "Dark by default?" })
      asked = thread.byte_messages.last
      sent = deliver("yes, dark by default")
      allow(BuddyDeliverWorker).to receive(:deliver_after_commit)

      reply = ByteMessageIntake.call(
        user:         user,
        conversation: thread,
        body:         "yes, dark by default",
        metadata:     { source: "web" },
        reply_to:     asked.id,
      )

      expect(sent).to have_been_requested
      expect(reply.metadata["reply_to"]["id"]).to eq(asked.id)
      expect(build.reload.question).to be_nil
      expect(BuddyDeliverWorker).not_to have_received(:deliver_after_commit)
    end

    it "says so in the thread when the Mini can't take the answer" do
      described_class.update_from_mini!(build, { "waiting_at" => Time.current.iso8601, "question" => "Dark by default?" })
      asked = thread.byte_messages.last
      stub_request(:post, %r{/byte/builder\z}).to_return(status: 502)

      ByteMessageIntake.call(user: user, conversation: thread, body: "yes", metadata: {}, reply_to: asked.id)

      expect(thread.byte_messages.last.body).to include("Couldn't reach the Mini", "**dark mode**")
      expect(build.reload.question).to eq("Dark by default?")
    end

    it "is no longer open once the build is working again" do
      build.update!(question: "Dark by default?", asked_at: Time.current)

      described_class.report_sessions!(machine: :mini, sessions: [
        { "build_id" => build.id, "kind" => "builder", "working" => true },
      ])

      expect(described_class.asking(user)).to be_empty
    end

    it "isn't open on a build that's over" do
      build.update!(question: "Dark by default?", asked_at: Time.current, status: :finished)

      expect(described_class.asking(user)).to be_empty
    end
  end

  describe "master moving" do
    before { allow(FeatureBuildSyncWorker).to receive(:perform_async) }

    it "has the Mini check open PRs against it" do
      build.update!(pr_url: "https://github.com/x/pull/42", pr_number: 42)

      expect(described_class.github!(:push, { "ref" => "refs/heads/master" })).to eq(:syncing)
      expect(FeatureBuildSyncWorker).to have_received(:perform_async)
    end

    it "is left alone for other branches, and when no build has a PR open" do
      build

      expect(described_class.github!(:push, { "ref" => "refs/heads/master" })).to eq(:ignored)
      build.update!(pr_url: "https://github.com/x/pull/42", pr_number: 42)
      expect(described_class.github!(:push, { "ref" => "refs/heads/byte/9-other" })).to eq(:ignored)
      expect(FeatureBuildSyncWorker).not_to have_received(:perform_async)
    end
  end

  describe ".start_from_request!" do
    let(:primary) { user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current) }
    let(:feature_request) {
      FeatureRequest.create!(user: user, title: "Repeating timers", body: "Every 30 minutes, a 10 minute break.")
    }

    before do
      allow(FeatureBuildStartWorker).to receive(:perform_async)
      allow(ByteConversation).to receive(:for_self_initiated).with(user).and_return(primary)
    end

    it "hands the title, body and notes to a build that speaks in the primary thread" do
      build = described_class.start_from_request!(feature_request, user: user, notes: "Keep it in Jil")

      expect(build.request).to eq("Repeating timers\n\nEvery 30 minutes, a 10 minute break.\n\nNotes: Keep it in Jil")
      expect(build.title).to eq("Repeating timers")
      expect(build.feature_request).to eq(feature_request)
      expect(build.byte_conversation).to eq(primary)
      expect(primary.byte_messages.last.body).to include("Starting a Feature Builder", "Repeating timers")
      expect(feature_request.reload).to be_status_planned
      expect(FeatureBuildStartWorker).to have_received(:perform_async).with(build.id)
    end

    it "leaves the notes out when there aren't any" do
      build = described_class.start_from_request!(feature_request, user: user, notes: "  ")

      expect(build.request).not_to include("Notes:")
    end

    it "doesn't start a second build while one is going, but does after one failed" do
      first = described_class.start_from_request!(feature_request, user: user)

      expect(described_class.start_from_request!(feature_request.reload, user: user)).to be_nil

      first.update!(status: :failed)
      expect(described_class.start_from_request!(feature_request.reload, user: user)).to be_present
    end

    it "doesn't build something shipped or declined" do
      feature_request.update!(status: :declined)

      expect(described_class.start_from_request!(feature_request, user: user)).to be_nil
    end

    it "marks the request shipped when the build's PR is merged, and not when it's closed" do
      merged = described_class.start_from_request!(feature_request, user: user)
      stub_request(:post, %r{/byte/builder\z}).to_return(status: 200, body: "{}")
      merged_pr = { "number" => 42, "head" => { "ref" => "byte/#{merged.id}-x" }, "merged" => true }

      closed_request = FeatureRequest.create!(user: user, title: "Other thing", body: "Something else")
      closed = described_class.start_from_request!(closed_request, user: user)
      closed_pr = { "number" => 43, "head" => { "ref" => "feature-builder/#{closed.id}-y" }, "merged" => false }

      described_class.github!(:pull_request, { "action" => "closed", "pull_request" => merged_pr })
      described_class.github!(:pull_request, { "action" => "closed", "pull_request" => closed_pr })

      expect(feature_request.reload).to be_status_shipped
      expect(closed_request.reload).to be_status_planned
      expect(closed_request).to be_buildable
    end
  end

  describe "builds waiting on the owner" do
    def chip
      BackgroundProcess.live_find(user, described_class::NEEDS_YOU_KEY)
    end

    def make(**attributes)
      FeatureBuild.create!(user: user, title: "Thing", request: "thing", status: :running, **attributes)
    end

    it "counts PRs still open, and not a plan it's building from" do
      make(planned_at: 1.hour.ago)
      going   = make(planned_at: 1.hour.ago)
      pr      = make(planned_at: 1.hour.ago, pr_url: "https://github.com/x/pull/1", pr_number: 1)
      make
      make(planned_at: 1.hour.ago, pr_url: "https://github.com/x/pull/2", status: :finished)

      described_class.report_sessions!(machine: :mini, sessions: [
        { "build_id" => going.id, "kind" => "builder", "working" => true },
      ])

      pending = described_class.pending(user)
      expect(pending.keys).to contain_exactly(:prs, :questions)
      expect(pending[:prs]).to eq([pr])
      expect(pending[:questions]).to be_empty
      expect(chip.name).to eq("1 build needs you")
      expect(chip).to be_waiting
      expect(chip.links.first["url"]).to end_with("/system/claude")
    end

    it "counts a build whose session is waiting on an answer, before its plan or after" do
      asking  = make
      stuck   = make(planned_at: 1.hour.ago)
      working = make
      make

      described_class.report_sessions!(machine: :mini, sessions: [
        { "build_id" => asking.id, "kind" => "builder", "working" => false },
        { "build_id" => stuck.id, "kind" => "builder", "working" => false },
        { "build_id" => working.id, "kind" => "builder", "working" => true },
      ])

      expect(described_class.pending(user)[:questions]).to contain_exactly(asking, stuck)
      expect(chip.name).to eq("2 builds need you")
    end

    it "is not raised by a plan, and is raised by the PR until it closes" do
      allow(Buddy::CompanionDelivery).to receive(:deliver_plain)
      described_class.update_from_mini!(build, { "planned_at" => Time.current.iso8601 })
      expect(chip).to be_nil

      described_class.update_from_mini!(build, { "pr_number" => 42, "pr_url" => "https://github.com/x/pull/42" })
      expect(chip.name).to eq("1 build needs you")
      stub_request(:post, %r{/byte/builder\z}).to_return(status: 200, body: "{}")
      described_class.github!(:pull_request, { "action" => "closed", "pull_request" => pull_request })

      expect(chip).to be_nil
    end
  end

  describe ".stage" do
    let(:build) { FeatureBuild.new(title: "Thing", request: "thing", status: :running) }

    it "says where a build has got to" do
      expect(described_class.stage(build, nil)).to eq("running")
      expect(described_class.stage(build, { "working" => false })).to eq("waiting on you")
      expect(described_class.stage(build, { "working" => true })).to eq("planning")
      build.planned_at = Time.current
      expect(described_class.stage(build, { "working" => true })).to eq("building")
      expect(described_class.stage(build, { "working" => false })).to eq("waiting on you")
      build.pr_url = "https://github.com/x/pull/1"
      expect(described_class.stage(build, nil)).to eq("PR open")
      expect(described_class.stage(build, { "working" => true })).to eq("working")
      build.status = :finished
      expect(described_class.stage(build, nil)).to eq("finished")
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

    it "keeps the build open and asks the Mini again later when it can't be told" do
      allow(FeatureBuildFinishWorker).to receive(:perform_in)

      outcome = described_class.github!(:pull_request, {
        "action"       => "closed",
        "pull_request" => pull_request(merged: true),
      })

      expect(outcome).to eq(:mini_unreachable)
      expect(build.reload).not_to be_status_finished
      expect(FeatureBuildFinishWorker).to have_received(:perform_in).with(anything, build.id, true)
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

    it "says a builder is planning until its plan is posted" do
      planning = FeatureBuild.create!(user: user, title: "A", request: "a", status: :running)
      building = FeatureBuild.create!(user: user, title: "B", request: "b", status: :running, planned_at: Time.current)

      report({ "build_id" => planning.id, "kind" => "builder", "working" => true })
      expect(chip.name).to eq("Planning…")

      report({ "build_id" => building.id, "kind" => "builder", "working" => true })
      expect(chip.name).to eq("Building…")

      report(
        { "build_id" => planning.id, "kind" => "builder", "working" => true },
        { "build_id" => building.id, "kind" => "builder", "working" => true },
      )
      expect(chip.name).to eq("2x Builders running")
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

    it "never puts the questions session on the chip" do
      report({ "kind" => "questions", "working" => true })
      expect(chip).to be_nil

      report(
        { "kind" => "questions", "working" => true },
        { "build_id" => 1, "kind" => "builder", "working" => true },
      )
      expect(chip.name).to eq("Building…")
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
