require "rails_helper"

# Every single-event mutation (Jil OR Buddy) must fire the :event trigger + the
# live broadcast — the side effects deliberately live here, not in a model
# callback (backfills skip callbacks). Buddy's event tools were skipping both.
RSpec.describe ActionEventNotifier do
  let(:user) { create(:user) }

  before do
    allow(::Jil).to receive(:trigger)
    allow(ActionEventBroadcastWorker).to receive(:perform_async)
    allow(UpdateActionStreak).to receive(:perform_async)
  end

  it "fires the :event trigger and the broadcast on add" do
    ev = ActionEvent.create!(user: user, name: "Coffee", timestamp: Time.current)

    described_class.notify(user, ev, :added, auth: :buddy, auth_id: user.id)

    expect(::Jil).to have_received(:trigger).with(user, :event, anything, hash_including(auth: :buddy, auth_id: user.id))
    expect(ActionEventBroadcastWorker).to have_received(:perform_async).with(ev.id, true)
  end

  it "re-anchors the following event's streak on removal" do
    older = ActionEvent.create!(user: user, name: "Coffee", timestamp: 2.hours.ago)
    newer = ActionEvent.create!(user: user, name: "Coffee", timestamp: 1.hour.ago)
    older.destroy!

    described_class.notify(user, older, :removed)

    expect(UpdateActionStreak).to have_received(:perform_async).with(newer.id)
  end

  describe "Buddy event tools" do
    let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
    let(:msg) { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

    before { allow(MonitorChannel).to receive(:broadcast_to) }

    def build(tool, payload)
      Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: [{ tool_name: tool, payload: payload, span: [0, 0] }])
    end

    it "log_event (L2) broadcasts + fires the :event trigger on log" do
      build(:log_event, { name: "Coffee" })
      expect(ActionEventBroadcastWorker).to have_received(:perform_async)
      expect(::Jil).to have_received(:trigger).with(user, :event, anything, hash_including(auth: :buddy))
    end

    it "undoing a Buddy log re-broadcasts + fires :event again (removed)" do
      action = build(:log_event, { name: "Coffee" })[:action]
      btn = action.buttons.first

      Buddy::ProposalExecutor.undo!(action.id, btn["id"])

      expect(ActionEvent.where(user: user, name: "Coffee")).not_to exist
      expect(ActionEventBroadcastWorker).to have_received(:perform_async).at_least(:twice) # log + undo
    end
  end
end
