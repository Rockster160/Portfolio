require "rails_helper"

# Lightweight recent-undo: the `undo` tool reverses the newest reversible Byte
# mutation in the conversation, using the `revert` descriptor the tool stashed
# on its executed proposal button.
RSpec.describe "Buddy undo" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }

  def executed_action(revert, tool: "log_event")
    ByteAction.create!(
      user: user, byte_conversation: convo, kind: :custom, tool_name: "buddy_proposals",
      multi_select: true, tool_input: {},
      buttons: [{ "id" => 1, "tool_name" => tool, "status" => "executed", "result" => { "revert" => revert } }],
    )
  end

  describe Buddy::Reverter do
    it "undo of a CREATE removes the record" do
      event  = ActionEvent.create!(user: user, name: "Coffee", timestamp: Time.current, data: {})
      described_class.call({ "op" => "created", "model" => "ActionEvent", "id" => event.id })
      expect(ActionEvent.exists?(event.id)).to be(false)
    end

    it "undo of an EDIT restores the prior values" do
      event = ActionEvent.create!(user: user, name: "Latte", timestamp: Time.current, data: {})
      described_class.call({ "op" => "updated", "model" => "ActionEvent", "id" => event.id, "before" => { "name" => "Coffee" } })
      expect(event.reload.name).to eq("Coffee")
    end

    it "undo of a DELETE recreates from the snapshot" do
      expect {
        described_class.call({ "op" => "recreated", "model" => "ActionEvent",
                               "attrs" => { "user_id" => user.id, "name" => "Water", "timestamp" => Time.current, "data" => {} } })
      }.to change { ActionEvent.where(user_id: user.id, name: "Water").count }.by(1)
    end
  end

  describe "the undo tool" do
    let(:tool) { Buddy::Tools[:undo] }
    let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }

    it "finds and reverses the most recent action, then marks it undone" do
      event  = ActionEvent.create!(user: user, name: "Coffee", timestamp: Time.current, data: {})
      action = executed_action({ "op" => "created", "model" => "ActionEvent", "id" => event.id, "summary" => "removed the Coffee log" })

      confirm = tool[:confirm].call({}, ctx)
      expect(confirm[:resolved][:byte_action_id]).to eq(action.id)
      expect(confirm[:summary]).to include("removed the Coffee log")

      tool[:execute].call(confirm[:resolved], ctx)

      expect(ActionEvent.exists?(event.id)).to be(false)              # reversed
      expect(action.reload.buttons.first["result"]["undone"]).to be(true)  # won't re-undo
    end

    it "raises (so Buddy can say so) when there's nothing to undo" do
      expect { tool[:confirm].call({}, ctx) }.to raise_error(/nothing recent to undo/)
    end

    it "skips an already-undone action and finds the previous one" do
      e1 = ActionEvent.create!(user: user, name: "First", timestamp: Time.current, data: {})
      e2 = ActionEvent.create!(user: user, name: "Second", timestamp: Time.current, data: {})
      older = executed_action({ "op" => "created", "model" => "ActionEvent", "id" => e1.id, "summary" => "removed First" })
      newer = executed_action({ "op" => "created", "model" => "ActionEvent", "id" => e2.id, "summary" => "removed Second" })

      # Undo once → hits the newer one.
      tool[:execute].call(tool[:confirm].call({}, ctx)[:resolved], ctx)
      expect(ActionEvent.exists?(e2.id)).to be(false)

      # Undo again → skips the undone newer, hits the older.
      tool[:execute].call(tool[:confirm].call({}, ctx)[:resolved], ctx)
      expect(ActionEvent.exists?(e1.id)).to be(false)
    end
  end
end
