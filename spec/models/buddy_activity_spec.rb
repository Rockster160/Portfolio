require "rails_helper"

RSpec.describe BuddyActivity do
  let(:user) { FactoryBot.create(:user) }
  let(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "T") }
  let(:msg) { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hi") }
  let(:log_event) { Buddy::Tools[:log_event] }
  let(:ctx) { Buddy::ToolContext.new(user, conversation: convo) }

  before { allow(ActionEventNotifier).to receive(:notify) }

  def checklist(name)
    ByteAction.create!(
      user:              user,
      byte_conversation: convo,
      byte_message:      msg,
      kind:              :custom,
      tool_name:         "buddy_proposals",
      multi_select:      true,
      buttons:           [{ "id" => 1, "label" => name, "tool_name" => "log_event", "payload" => { "name" => name }, "status" => "pending" }],
      decision:          {},
      tool_input:        {},
    )
  end

  describe "recording from Buddy::Tools.dispatch" do
    it "records what an acting call did, with the way back", :aggregate_failures do
      outcome = Buddy::Tools.dispatch(log_event, { name: "Coffee" }, ctx)
      activity = described_class.find(outcome[:activity_id])
      event = ActionEvent.find(outcome[:data][:action_event_id])

      expect(activity).to have_attributes(user: user, byte_conversation: convo, tool_name: "log_event", ok: true)
      expect(activity.payload).to eq("name" => "Coffee")
      expect(activity.receipt).to include("Coffee")
      expect(activity.reverts).to eq([{ "op" => "created", "model" => "ActionEvent", "id" => event.id, "summary" => "removed the Coffee log" }])
      expect(activity).to be_undoable
    end

    it "records a failed call with its error and nothing to undo", :aggregate_failures do
      outcome = Buddy::Tools.dispatch(log_event, { name: nil }, ctx)
      activity = described_class.find(outcome[:activity_id])

      expect(activity.ok).to be(false)
      expect(activity.error_message).to be_present
      expect(activity.reverts).to eq([])
      expect(activity).not_to be_undoable
    end

    it "leaves a lookup out" do
      lookup = Buddy::Tools.all.find { |tool| tool[:answers] && !tool[:acts] }

      expect { Buddy::Tools.dispatch(lookup, {}, ctx) }.not_to change(described_class, :count)
    end

    it "still runs the tool when recording fails" do
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::StatementInvalid)

      outcome = Buddy::Tools.dispatch(log_event, { name: "Coffee" }, ctx)

      expect(outcome).to include(ok: true)
      expect(outcome).not_to have_key(:activity_id)
    end
  end

  describe "#undo!" do
    it "walks back a call that ran outside a checklist", :aggregate_failures do
      outcome = Buddy::Tools.dispatch(log_event, { name: "Coffee" }, ctx)
      activity = described_class.find(outcome[:activity_id])

      expect(activity.undo!).to eq("removed the Coffee log")
      expect(ActionEvent.exists?(outcome[:data][:action_event_id])).to be(false)
      expect(activity.reload.undone_at).to be_present
      expect { activity.undo! }.to raise_error(/already been undone/)
    end

    # Undoing here and unticking in the chat are the same act, so whichever
    # happens first settles the other.
    it "undoes through the checklist row, keeping the chat in step", :aggregate_failures do
      action = checklist("Tea")
      Buddy::ProposalExecutor.perform(action.id, [1])
      button = action.reload.buttons.first
      activity = described_class.find(button["activity_ids"].sole)

      activity.undo!

      expect(ActionEvent.where(user: user).count).to eq(0)
      expect(action.reload.buttons.first).to include("status" => "undone", "undoable" => false)
      expect(activity.reload.undone_at).to be_present
    end

    it "is settled by an untick in the chat", :aggregate_failures do
      action = checklist("Tea")
      Buddy::ProposalExecutor.perform(action.id, [1])
      activity = described_class.find(action.reload.buttons.first["activity_ids"].sole)

      Buddy::ProposalExecutor.undo!(action.id, 1)

      expect(activity.reload.undone_at).to be_present
      expect(activity).not_to be_undoable
    end

    it "does not undo twice when the row was undone by asking Buddy", :aggregate_failures do
      action = checklist("Tea")
      Buddy::ProposalExecutor.perform(action.id, [1])
      activity = described_class.find(action.reload.buttons.first["activity_ids"].sole)
      # The `undo` tool marks the row's result, not its status.
      buttons = action.buttons.map(&:deep_dup)
      buttons.first["result"]["undone"] = true
      action.update!(buttons: buttons)

      expect { activity.undo! }.to raise_error(/already been undone/)
      expect(activity.reload.undone_at).to be_present
    end
  end

  it "sweeps rows past the retention window" do
    old = described_class.create!(user: user, tool_name: "log_event", created_at: (described_class::RETAIN_FOR + 1.day).ago)
    kept = described_class.create!(user: user, tool_name: "log_event")

    BuddyActivitySweepWorker.new.perform

    expect(described_class.where(id: [old.id, kept.id]).pluck(:id)).to eq([kept.id])
  end
end
