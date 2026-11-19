require "rails_helper"

RSpec.describe FeatureBuilder::Quick do
  let(:user) { User.me }
  let(:thread) { user.byte_conversations.create!(name: :Buddy, mode: :buddy) }

  before { allow(FeatureBuildStartWorker).to receive(:perform_async) }

  def said(body, direction: :outbound, at: Time.current, metadata: {})
    thread.byte_messages.create!(
      user:       user,
      direction:  direction,
      state:      direction == :outbound ? :sent : :delivered,
      body:       body,
      metadata:   metadata,
      created_at: at,
    )
  end

  describe ".start!" do
    it "starts a quick build named for the question, under their message" do
      posted = described_class.start!(user: user, conversation: thread, text: "why did the gate sound twice?")

      build = FeatureBuild.last
      expect(build).to be_kind_quick
      expect(build.request).to start_with("Quick request: why did the gate sound twice?")
      expect(posted.body).to eq("/q why did the gate sound twice?")
      expect(posted.metadata).to include("feature_build_id" => build.id)
      expect(build.byte_message.body).to include("Starting a quick session on the Mini")
      expect(FeatureBuildStartWorker).to have_received(:perform_async).with(build.id, "why did the gate sound twice?")
    end

    it "quotes the message it was typed as a reply to" do
      answer = said("It fired twice.", direction: :inbound)

      posted = described_class.start!(user: user, conversation: thread, text: "and today?", reply_to_id: answer.id)

      expect(posted.metadata["reply_to"]).to include("id" => answer.id)
      expect(posted.metadata["feature_build_id"]).to eq(FeatureBuild.last.id)
    end

    it "explains itself without a question" do
      described_class.start!(user: user, conversation: thread, text: " ")

      expect(FeatureBuild.count).to eq(0)
      expect(thread.byte_messages.last.body).to include("usage")
    end
  end

  describe "a reply after the session has closed" do
    let!(:earlier) {
      described_class.start!(user: user, conversation: thread, text: "how many users?")
      FeatureBuild.last
    }

    it "starts a new session carrying the earlier one, and moves the reply to it" do
      tag = { feature_build_id: earlier.id }
      said("346 real accounts.", direction: :inbound, metadata: tag)
      earlier.update!(status: :finished, closed_reason: "no reply in 6 hours.")
      reply = said("and admins?", metadata: tag)

      expect(FeatureBuilder.answer_from_thread!(earlier, reply)).to be(true)

      build = FeatureBuild.last
      expect(build).to have_attributes(kind: "quick", title: earlier.title)
      expect(build.id).not_to eq(earlier.id)
      expect(build.request).to start_with("Quick request: and admins?")
      expect(build.request).to include(
        "carries on an earlier session",
        "Quick request: how many users?",
        "/q how many users?",
        "346 real accounts.",
      )
      expect(build.request).not_to include("Looking into", "Starting a quick session")
      expect(reply.reload.metadata["feature_build_id"]).to eq(build.id)
      expect(FeatureBuilder.replied_to(user, reply)).to eq(build)
    end

    it "leaves a closed feature build closed" do
      earlier.update!(kind: :feature, status: :finished)
      reply = said("one more thing", metadata: { feature_build_id: earlier.id })

      expect { FeatureBuilder.answer_from_thread!(earlier, reply) }.not_to change(FeatureBuild, :count)
      expect(thread.byte_messages.last.body).to include("no session left")
    end
  end

  describe ".brief" do
    it "hands over the thread's last 30 messages, oldest first, without hidden seeds" do
      35.times { |index| said("message #{index}", at: (40 - index).minutes.ago) }
      said("a seed", metadata: { hidden: true })

      brief = described_class.brief(thread, "what happened?")

      expect(brief).to include("message 34", "message 5")
      expect(brief).not_to include("message 4\n", "a seed")
      expect(brief.index("message 5")).to be < brief.index("message 34")
    end

    it "follows the reply chain it was typed under" do
      first = said("the gate sounded", direction: :inbound, at: 50.days.ago)
      second = said("again?", at: 49.days.ago, metadata: { reply_to: { id: first.id } })

      brief = described_class.brief(thread, "why?", second)

      expect(brief).to include("typed as a reply to this", "[#{first.id}]", "[#{second.id}]")
    end
  end

  describe ".close_idle!" do
    before { allow(ByteLocal).to receive(:builder).and_return(true) }

    def quick_build(created_at)
      FeatureBuild.create!(
        user: user, byte_conversation: thread, title: "Q", request: "q", kind: :quick,
        status: :running, created_at: created_at
      )
    end

    it "closes a quick session nobody has replied to in 6 hours, and leaves the rest" do
      quiet = quick_build(8.hours.ago)
      replied = quick_build(8.hours.ago)
      said("one more thing", at: 1.hour.ago, metadata: { feature_build_id: replied.id })
      fresh = quick_build(1.hour.ago)
      feature = FeatureBuild.create!(
        user: user, title: "F", request: "f", status: :running, created_at: 3.days.ago,
      )

      expect(described_class.close_idle!).to eq([quiet])

      expect(quiet.reload).to have_attributes(status: "finished", closed_reason: described_class::IDLE_REASON)
      expect([replied, fresh, feature].map { |build| build.reload.status }).to all(eq("running"))
    end
  end
end
