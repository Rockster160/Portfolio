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
      buttons: [{ "id" => 1, "tool_name" => tool, "status" => "executed", "result" => { "revert" => revert } }]
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
        described_class.call({
          "op"    => "recreated",
          "model" => "ActionEvent",
          "attrs" => { "user_id" => user.id, "name" => "Water", "timestamp" => Time.current, "data" => {} },
        })
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

  # Prod: the undo row was tapped, it removed a chore completion carrying the
  # note "built rocking chair", and there was no way back — `remove` destroyed
  # the row and kept nothing, so re-marking the chore produced a bare completion
  # with the note gone. An undo that can't be undone is a delete with a friendly
  # name.
  describe "undoing an undo" do
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
    let(:chore)      { create(:chore, created_by_user: user, chore_household: household, name: "1hr Project") }

    def completion!(note)
      ChoreCompletion.create!(
        user: user, chore: chore, completed_at: 3.hours.ago,
        day_key: ChoreDay.current(user, at: 3.hours.ago), note: note
      )
    end

    it "hands back what it takes away, note and all" do
      done   = completion!("built rocking chair")
      action = executed_action(
        { "op" => "created", "model" => "ChoreCompletion", "id" => done.id, "summary" => "unmarked 1hr Project" },
        tool: "complete_chore",
      )

      out = Buddy::Reverter.perform!(action.id, 1)

      expect(ChoreCompletion.exists?(done.id)).to be(false)
      expect(out[:reverts].first).to include("op" => "recreated", "model" => "ChoreCompletion")
      expect(out[:reverts].first["attrs"]).to include("note" => "built rocking chair")
    end

    it "puts the completion back, with its note, when the undo is reversed" do
      done   = completion!("built rocking chair")
      action = executed_action(
        { "op" => "created", "model" => "ChoreCompletion", "id" => done.id, "summary" => "unmarked 1hr Project" },
        tool: "complete_chore",
      )
      out = Buddy::Reverter.perform!(action.id, 1)

      out[:reverts].each { |rv| Buddy::Reverter.call(rv) }

      restored = ChoreCompletion.where(chore_id: chore.id, user_id: user.id).last
      expect(restored.note).to eq("built rocking chair")
      expect(restored.day_key).to eq(done.day_key)
    end

    # The snapshot has to be taken while the row still exists, so a descriptor
    # pointing at something already gone simply carries no way back rather than
    # blowing up the undo.
    it "still undoes something that's already gone, without an inverse" do
      action = executed_action(
        { "op" => "created", "model" => "ChoreCompletion", "id" => 999_999, "summary" => "unmarked whatever" },
        tool: "complete_chore",
      )

      expect { Buddy::Reverter.perform!(action.id, 1) }.to raise_error(/already gone/)
    end

    # The whole loop the way the person meets it: tap Undo, realise it was the
    # wrong thing, uncheck it.
    it "reverses all the way back through the checklist row" do
      before_action = executed_action(
        {
          "op"      => "created",
          "model"   => "ChoreCompletion",
          "id"      => completion!("built rocking chair").id,
          "summary" => "unmarked 1hr Project",
        },
        tool: "complete_chore",
      )
      undo_row = ByteAction.create!(
        user: user, byte_conversation: convo, kind: :custom, tool_name: "buddy_proposals",
        multi_select: true, tool_input: {},
        buttons: [{
          "id"        => 1,
          "tool_name" => "undo",
          "status"    => "pending",
          "payload"   => { "byte_action_id" => before_action.id, "button_id" => 1 },
        }]
      )

      Buddy::ProposalExecutor.perform(undo_row.id, [1])
      row = undo_row.reload.buttons.first
      expect(ChoreCompletion.where(chore_id: chore.id)).to be_empty
      expect(row["status"]).to eq("executed")
      expect(row["undoable"]).to be(true)

      Buddy::ProposalExecutor.undo!(undo_row.id, 1)

      expect(undo_row.reload.buttons.first["status"]).to eq("undone")
      expect(ChoreCompletion.where(chore_id: chore.id).last.note).to eq("built rocking chair")
    end
  end

  # Prod 1362: told the routine it had just saved was wrong, Buddy offered to
  # undo a chore completion from five hours earlier — simply the newest
  # reversible thing left in the thread. `undo` takes no arguments, so it can
  # only ever mean "the thing you just did"; anything they'd have to NAME
  # belongs to a tool that takes a name.
  describe "how far back undo will reach" do
    let(:tool) { Buddy::Tools[:undo] }
    let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }

    def aged_action(hours, name)
      event  = ActionEvent.create!(user: user, name: name, timestamp: Time.current, data: {})
      action = executed_action({ "op" => "created", "model" => "ActionEvent", "id" => event.id, "summary" => "removed #{name}" })
      action.update_columns(created_at: hours.hours.ago)
      [event, action]
    end

    it "does not reach past the window for something they'd have to name" do
      aged_action(5, "Rocking Chair")

      expect { tool[:confirm].call({}, ctx) }.to raise_error(/nothing recent to undo/)
    end

    it "still finds something from the current exchange" do
      _event, action = aged_action(0, "Coffee")

      expect(tool[:confirm].call({}, ctx)[:resolved][:byte_action_id]).to eq(action.id)
    end

    it "skips the stale one and takes the recent one when both are there" do
      aged_action(5, "Rocking Chair")
      _recent, action = aged_action(0, "Coffee")

      expect(tool[:confirm].call({}, ctx)[:summary]).to include("Coffee")
      expect(tool[:confirm].call({}, ctx)[:resolved][:byte_action_id]).to eq(action.id)
    end
  end
end
