require "rails_helper"

RSpec.describe "Buddy undo" do
  # Lightweight recent-undo: the `undo` tool reverses the newest reversible Byte
  # mutation in the conversation, using the `revert` descriptor the tool stashed
  # on its executed proposal button.
  describe "undoing" do
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

      # Everything hung off a list watches the `:item` Jil trigger, and
      # `soft_destroy` alone is a bare `update(deleted_at:)` that fires nothing.
      describe "undo of a list item" do
        let(:list) { create(:list, user: user) }
        let(:fired) { [] }

        before {
          allow(::Jil).to receive(:trigger) { |u, scope, data, **|
            fired << [u, scope, data.with_indifferent_access]
          }
        }

        def undo!(item)
          described_class.call({ "op" => "created", "model" => "ListItem", "id" => item.id })
        end

        it "takes the item off the list and fires :item removed", :aggregate_failures do
          item = list.list_items.add("Turn off the lamp")
          fired.clear

          undo!(item)

          u, scope, data = fired.last
          expect(u).to eq(user)
          expect(scope).to eq(:item)
          expect(data[:action]).to eq(:removed)
          expect(data[:name]).to eq("Turn off the lamp")
          expect(list.list_items.reload.map(&:name)).to be_empty
        end

        # `find!` gets there first — `default_scope` hides a soft-deleted item,
        # so an undo tapped twice says so rather than firing `:removed` again.
        it "says nothing twice when the item was already gone" do
          item = list.list_items.add("Bins out")
          item.soft_destroy
          fired.clear

          expect { undo!(item) }.to raise_error(/already gone/)
          expect(fired).to be_empty
        end
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

    # An undo hands back a revert of its own, so it can be reversed with the
    # record's details (a completion's note) intact.
    describe "undoing an undo" do
      let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
      let(:chore)      { create(:chore, created_by_user: user, chore_household: household, name: "1hr Project") }

      def completion!(note)
        ChoreCompletion.create!(
          user: user, chore: chore, completed_at: 3.hours.ago,
          day_key: ChoreDay.current(user, at: 3.hours.ago), note: note
        )
      end

      it "hands back what it takes away, and puts it back note and all", :aggregate_failures do
        done   = completion!("built rocking chair")
        action = executed_action(
          { "op" => "created", "model" => "ChoreCompletion", "id" => done.id, "summary" => "unmarked 1hr Project" },
          tool: "complete_chore",
        )

        out = Buddy::Reverter.perform!(action.id, 1)

        expect(ChoreCompletion.exists?(done.id)).to be(false)
        expect(out[:reverts].first).to include("op" => "recreated", "model" => "ChoreCompletion")

        out[:reverts].each { |rv| Buddy::Reverter.call(rv) }

        restored = ChoreCompletion.where(chore_id: chore.id, user_id: user.id).last
        expect(restored.note).to eq("built rocking chair")
        expect(restored.day_key).to eq(done.day_key)
      end

      # Cancelling is a soft remove, so reversing it flips the columns back
      # rather than recreating a duplicate.
      it "un-cancels the agenda item it cancelled, rather than making a second one" do
        agenda = create(:agenda, user: user)
        item   = agenda.agenda_items.create!(
          name: "Cover tomatoes", kind: :event, start_at: 2.hours.from_now, end_at: 4.hours.from_now,
        )
        action = executed_action(
          { "op" => "created", "model" => "AgendaItem", "id" => item.id, "summary" => "removed Cover tomatoes" },
          tool: "add_agenda_item",
        )

        out = Buddy::Reverter.perform!(action.id, 1)
        expect(item.reload.cancelled_at).to be_present

        out[:reverts].each { |rv| Buddy::Reverter.call(rv) }

        expect(item.reload.cancelled_at).to be_nil
        expect(AgendaItem.where(name: "Cover tomatoes").count).to eq(1)
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

    # `undo` takes no arguments, so it can only ever mean "the thing you just
    # did"; anything older they'd have to name.
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

      it "skips the stale one and takes the recent one when both are there" do
        aged_action(5, "Rocking Chair")
        _recent, action = aged_action(0, "Coffee")

        expect(tool[:confirm].call({}, ctx)[:summary]).to include("Coffee")
        expect(tool[:confirm].call({}, ctx)[:resolved][:byte_action_id]).to eq(action.id)
      end
    end
  end

  # The mirror of a disputed action. There, the person says something DIDN'T
  # happen; here they say something that DID happen shouldn't have, and the
  # reply must check recent_actions rather than answer from memory.
  describe "regret" do
    let(:user) { User.me }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      convo.update_columns(buddy_theme: "byte", buddy_expression: "happy")
    end

    def user_says(text)
      convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: text)
    end

    def run(rounds, text:)
      client = FakeBuddyClient.new(rounds)
      Buddy::GPT::Turn.run!(user_says(text), client: client)
      client
    end

    def nudges(client)
      client.calls.filter_map { |c| c.input.last[:content] if c.input.last[:role] == :developer }
    end

    describe "recognizing it" do
      def regrets?(text) = Buddy::GPT::Turn::UNDO_REGRET_RX.match?(text)

      # A false fire costs one corrective round, so this is about staying out of
      # ordinary conversation rather than about precision.
      it "catches regret and leaves ordinary messages alone", :aggregate_failures do
        [
          "No, I didn't mean to undo that!",
          "I didn’t mean to remove it",
          "why did you delete that",
          "can you put it back",
          "I still want that one",
          "undo the undo please",
        ].each { |text| expect(regrets?(text)).to be(true), text }

        [
          "go ahead and undo that", "I didn't mean to say that", "remove the second one please", "did you undo it?"
        ].each { |text| expect(regrets?(text)).to be(false), text }
      end

      # The other half of the pair still has its own arm; neither is a subset of
      # the other and both have to keep firing on their own shapes.
      it "doesn't take over from the disputed-action check" do
        expect(Buddy::GPT::Turn::DISPUTED_ACTION_RX.match?("No, I didn't mean to undo that!")).to be(false)
        expect(regrets?("you never sent it")).to be(false)
      end
    end

    describe "a reply written without looking" do
      let(:regret) { "No, I didn't mean to undo that!" }

      it "gets a corrective round telling it to read recent_actions" do
        client = run(
          [
            { text: "No worries at all!! Nothing got undone on my side, so you're still good!" },
            { tool_calls: [{ name: :get_context, arguments: { "sections" => ["recent_actions"] } }] },
            { text: "You're right, lekker came off — putting it back now." },
          ],
          text: regret,
        )

        expect(nudges(client)).to eq([Buddy::GPT::Turn::UNDO_REGRET_NUDGE])
      end

      it "spends only the one round on it" do
        client = run(
          [
            { text: "Nothing got undone!" },
            { text: "Nothing got undone!" },
            { text: "Nothing got undone!" },
          ],
          text: regret,
        )

        expect(nudges(client).count(Buddy::GPT::Turn::UNDO_REGRET_NUDGE)).to eq(1)
      end

      # The whole point of the nudge is that putting it back is a call, not a
      # sentence — so a turn that goes and does it is left alone.
      it "is left alone once it has looked" do
        client = run(
          [
            { tool_calls: [{ name: :get_context, arguments: { "sections" => ["recent_actions"] } }] },
            { text: "Yep, that one came off — back on now." },
          ],
          text: regret,
        )

        expect(nudges(client)).to be_empty
      end
    end

    # Nobody spoke, so there's nothing to regret.
    it "never fires on a self-initiated turn" do
      seed = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :pending,
        body: "Say something about the day", metadata: { "kind" => "buddy_trigger", "hidden" => true }
      )
      client = FakeBuddyClient.new([{ text: "Nothing got undone, put it back on the list." }])
      Buddy::GPT::Turn.run!(seed, client: client)

      expect(nudges(client)).to be_empty
    end
  end
end
