require "rails_helper"

# A prompt form with a live duration on it: re-run its load step every minute
# while it waits, and only then.
RSpec.describe BuddyFormTickWorker do
  let(:user) { User.me }
  let!(:conversation) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let(:live) { true }
  let(:prompt) {
    user.prompts.create!(
      question: "How was your shower?",
      params:   { action_event_id: 1 },
      options:  [
        { type: :duration, question: "Duration", default: "5", live: live }.compact,
        { type: :text, question: "Notes", default: "" },
      ],
    )
  }
  let(:action) { Buddy::PromptDelivery.post!(user, prompt) }
  let(:loads) { [] }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    # Inline Sidekiq would run every tick on the spot, forever.
    allow(described_class).to receive(:perform_in)
    allow(Buddy::FormAction).to receive(:stop_tick!).and_call_original
    allow(Jil).to receive(:trigger).and_call_original
    allow(Jil).to receive(:trigger).with(user, :prompt, anything, auth: :trigger) { |_, _, data|
      loads << data[:state]
    }
  end

  it "is scheduled when a form with a live duration is posted" do
    action

    expect(described_class).to have_received(:perform_in).with(1.minute, action.id).once
  end

  context "with a duration that isn't live" do
    let(:live) { nil }

    it "is never scheduled" do
      action

      expect(described_class).not_to have_received(:perform_in)
    end
  end

  describe "a tick" do
    it "runs the load step and schedules the next one", :aggregate_failures do
      action
      loads.clear

      described_class.new.perform(action.id)

      expect(loads).to eq([:load])
      expect(described_class).to have_received(:perform_in).with(1.minute, action.id).twice
    end

    it "does nothing once the form was posted a day ago", :aggregate_failures do
      action.update!(created_at: 25.hours.ago)
      loads.clear

      described_class.new.perform(action.id)

      expect(loads).to be_empty
      expect(described_class).to have_received(:perform_in).once
    end

    it "does nothing once the prompt is answered", :aggregate_failures do
      action
      prompt.update!(response: { "Notes" => "Quick" })
      loads.clear

      described_class.new.perform(action.id)

      expect(loads).to be_empty
      expect(described_class).to have_received(:perform_in).once
    end
  end

  describe "stopping" do
    it "drops the waiting tick when the form is skipped" do
      action
      Buddy::PromptDelivery.dispatch(user, :prompt, prompt.with_jil_attrs(status: :skip))

      expect(Buddy::FormAction).to have_received(:stop_tick!).with(action.id)
    end

    it "drops it when the prompt is deleted" do
      action
      prompt.destroy!

      expect(Buddy::FormAction).to have_received(:stop_tick!).with(action.id)
    end

    it "drops it when the form is answered" do
      action
      Buddy::FormAction.settle!(action.reload, receipt: "Sent ✓")

      expect(Buddy::FormAction).to have_received(:stop_tick!).with(action.id)
    end

    it "deletes only this form's scheduled tick" do
      mine  = instance_double(Sidekiq::SortedEntry, klass: described_class.name, args: [41], delete: true)
      other = instance_double(Sidekiq::SortedEntry, klass: described_class.name, args: [42], delete: true)
      allow(Sidekiq::ScheduledSet).to receive(:new).and_return([mine, other])

      Buddy::FormAction.stop_tick!(41)

      expect(mine).to have_received(:delete)
      expect(other).not_to have_received(:delete)
    end
  end

  describe "PromptQuestion.duration" do
    it "marks a live one, and leaves the rest as they were", :aggregate_failures do
      exe = Jil::Executor.call(
        user,
        <<~JIL,
          a = PromptQuestion.duration("Duration", 5, true)::PromptQuestion
          b = PromptQuestion.duration("Nap", 20)::PromptQuestion
        JIL
      )

      expect(exe.ctx[:vars][:a][:value]).to include(type: :duration, live: true)
      expect(exe.ctx[:vars][:b][:value]).not_to have_key(:live)
    end
  end
end
