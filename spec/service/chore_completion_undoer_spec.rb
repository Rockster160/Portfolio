require "rails_helper"

# Undoing a chore completion must fire the SAME callbacks as a tap-undo in the
# Chores app — destroy + streak rebuild + broadcast — so open Chores clients
# reflect the undo. The bug: Buddy's undo destroyed the completion but never
# broadcast, so the Chores app didn't update.
RSpec.describe ChoreCompletionUndoer do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:chore) { household.chores.create!(created_by_user: user, name: "Dishes") }

  before do
    user.update!(chore_household_id: household.id)
    allow(::Jil).to receive(:trigger)
    allow(ChoreBroadcaster).to receive(:broadcast_changes!)
    allow(ChoreStreak).to receive(:rebuild_for!)
  end

  def completion
    ChoreCompletion.create!(user: user, chore: chore, completed_at: Time.current, day_key: user.perceived_today)
  end

  it "destroys the completion, rebuilds the streak, and broadcasts to the Chores app" do
    c = completion

    expect { described_class.call(user, c) }.to change(ChoreCompletion, :count).by(-1)
    expect(ChoreStreak).to have_received(:rebuild_for!).with(user, chore)
    expect(ChoreBroadcaster).to have_received(:broadcast_changes!).with(user, chore, hash_including(related: nil))
  end

  it "is a safe no-op on a nil completion" do
    expect { described_class.call(user, nil) }.not_to raise_error
  end

  describe "Buddy's Level-2 complete_chore undo path" do
    let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
    let(:msg) { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

    before { allow(MonitorChannel).to receive(:broadcast_to) }

    it "removes the completion AND broadcasts on undo" do
      action = Buddy::ProposalBuilder.create(
        user: user, byte_message: msg,
        markers: [{ tool_name: :complete_chore, payload: { chore: "Dishes" }, span: [0, 0] }]
      )[:action]
      btn = action.buttons.first
      expect(btn["status"]).to eq("executed")
      expect(ChoreCompletion.count).to eq(1)

      Buddy::ProposalExecutor.undo!(action.id, btn["id"])

      expect(ChoreCompletion.count).to eq(0)
      expect(ChoreBroadcaster).to have_received(:broadcast_changes!).with(user, chore, anything).at_least(:once)
    end
  end
end
