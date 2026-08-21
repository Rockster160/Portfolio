require "rails_helper"

RSpec.describe Buddy::ProposalBuilder do
  describe "building proposals" do
    describe "building proposals" do
      let(:user) { FactoryBot.create(:user) }
      let(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "T") }
      let(:msg)   { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hello") }

      before do
        allow(MonitorChannel).to receive(:broadcast_to)
        # A tiny synthetic CONFIRM tool for shape testing so we don't depend on
        # the real tool files (their resolvers hit Chore/Agenda models).
        Buddy::Tools.register(
          name:        :spec_noop,
          description: "no-op used in specs",
          args:        { thing: { type: :string, required: true } },
          confirm:     ->(p, _) { { summary: "Do #{p[:thing]}?", resolved: {} } },
          label:       ->(p, _) { p[:thing].to_s },
          merge_key:   ->(p) { "spec_noop:#{p[:thing]}" },
          merge_label: ->(p, n) { "#{n}× #{p[:thing]}" },
          execute:     ->(p, _) { { echoed: p[:thing] } },
          receipt:     ->(r, _) { "Did #{r[:echoed]}" },
        )
      end

      it "creates a ByteAction with per-marker button rows" do
        markers = [
          { tool_name: :spec_noop, payload: { thing: "one" }, span: [0, 0] },
          { tool_name: :spec_noop, payload: { thing: "two" }, span: [0, 0] },
        ]
        result = described_class.create(user: user, byte_message: msg, markers: markers)
        action = result[:action]

        expect(action).to be_a(ByteAction)
        expect(action.multi_select).to be(true)
        expect(action.tool_name).to eq("buddy_proposals")
        expect(action.buttons.length).to eq(2)
        expect(action.buttons.map { |b| b["label"] }).to eq(%w[one two])
        expect(result[:auto_ran]).to be(false)

        msg.reload
        expect(msg.metadata["kind"]).to eq("buddy_reply")
        expect(msg.metadata["action_request_id"]).to eq(action.request_id)
      end

      it "merges identical proposals via merge_key with total count" do
        markers = Array.new(3) { { tool_name: :spec_noop, payload: { thing: "same" }, span: [0, 0] } }
        action = described_class.create(user: user, byte_message: msg, markers: markers)[:action]

        expect(action.buttons.length).to eq(1)
        expect(action.buttons.first["count"]).to eq(3)
        expect(action.buttons.first["label"]).to eq("3× same")
      end

      it "discards markers whose tool is unknown" do
        markers = [
          { tool_name: :spec_noop,   payload: { thing: "ok" },   span: [0, 0] },
          { tool_name: :not_a_thing, payload: { thing: "nope" }, span: [0, 0] },
        ]
        action = described_class.create(user: user, byte_message: msg, markers: markers)[:action]

        expect(action.buttons.length).to eq(1)
        expect(action.buttons.first["label"]).to eq("ok")
      end

      it "returns no action when no markers survive validation" do
        markers = [{ tool_name: :not_a_thing, payload: {}, span: [0, 0] }]
        result = described_class.create(user: user, byte_message: msg, markers: markers)
        expect(result[:action]).to be_nil
        expect(result[:auto_ran]).to be(false)
      end

      context "auto (no-confirm) tools" do
        before do
          Buddy::Tools.register(
            name:        :spec_auto,
            description: "auto tool used in specs",
            args:        { thing: { type: :string, required: true } },
            confirm:     ->(p, _) { { summary: "x", resolved: {} } },
            label:       ->(p, _) { p[:thing].to_s },
            execute:     ->(p, _) { { echoed: p[:thing] } },
            receipt:     ->(r, _) { "Handled #{r[:echoed]}" },
            auto:        true,
          )
        end

        it "runs immediately, posts an activity chip, and creates NO checklist" do
          markers = [{ tool_name: :spec_auto, payload: { thing: "reminder" }, span: [0, 0] }]

          expect {
            result = described_class.create(user: user, byte_message: msg, markers: markers)
            expect(result[:action]).to be_nil
            expect(result[:auto_ran]).to be(true)
          }.to change { convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").count }.by(1)

          chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
          # Receipt first, then the record of WHICH tool ran - a level-1 action has
          # no checklist row, so the chip is the only trace it leaves.
          expect(chip.body).to eq("Handled reminder")
          expect(chip.metadata["tool_name"]).to eq("spec_auto")
          expect(chip.direction).to eq("inbound")
        end

        it "mixes: auto runs, confirm tool still becomes a checklist" do
          markers = [
            { tool_name: :spec_auto, payload: { thing: "r" }, span: [0, 0] },
            { tool_name: :spec_noop, payload: { thing: "c" }, span: [0, 0] },
          ]
          result = described_class.create(user: user, byte_message: msg, markers: markers)

          expect(result[:auto_ran]).to be(true)
          expect(result[:action].buttons.map { |b| b["label"] }).to eq(["c"])
        end
      end
    end

    # Tapping an EXPIRED proposal row reissues it as a fresh, tappable checklist on
    # a new message — the person never has to re-type the request.
    describe "reissue" do
      let(:user) { create(:user) }
      let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
      let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
      let(:msg) { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

      before do
        user.update!(chore_household_id: household.id)
        allow(MonitorChannel).to receive(:broadcast_to)
      end

      it "rebuilds the proposal from a stored button onto a fresh message + action" do
        action = Buddy::ProposalBuilder.create(
          user: user, byte_message: msg,
          markers: [{ tool_name: :create_chore, payload: { name: "Fill Kitty Litter", schedule: "daily" }, span: [0, 0] }]
        )[:action]
        button = action.buttons.first

        expect {
          Buddy::ProposalBuilder.reissue(user: user, conversation: convo, button: button)
        }.to change { ByteAction.where(byte_conversation: convo).count }.by(1)

        fresh = ByteAction.where(byte_conversation: convo).order(:created_at).last
        expect(fresh.id).not_to eq(action.id)
        expect(fresh).to be_pending
        expect(fresh.expires_at).to be > 1.day.from_now                 # a fresh, long window
        expect(fresh.buttons.first["label"]).to eq("Fill Kitty Litter") # same request, re-resolved
        expect(fresh.byte_message.body).to eq("Here you go again:")
      end

      it "degrades to an honest note when the reissued proposal can't rebuild" do
        # An unknown tool → nothing rebuilds.
        ByteAction.where(byte_conversation: convo).count # baseline
        result = Buddy::ProposalBuilder.reissue(
          user: user, conversation: convo,
          button: { "tool_name" => "totally_unknown_tool", "payload" => { "x" => "1" } }
        )

        expect(result[:action]).to be_nil
        note = convo.byte_messages.order(:created_at).last
        expect(note.body).to match(/couldn't set that back up/i)
      end
    end

    describe "TTL and label detail" do
      let(:user) { create(:user) }
      let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
      let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
      let(:msg) { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

      before do
        user.update!(chore_household_id: household.id)
        allow(MonitorChannel).to receive(:broadcast_to)
      end

      def build(markers)
        Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
      end

      it "gives a Buddy checklist a long TTL, not the 10-minute default (so a later tap still works)" do
        action = build([{ tool_name: :create_chore, payload: { name: "Water the ficus" }, span: [0, 0] }])[:action]
        expect(action.expires_at).to be > 1.day.from_now
        expect(action).to be_pending
        # And the expiry rides on the message metadata so the client can grey out
        # a stale row instead of letting the person tap into nothing.
        expect(action.byte_message.reload.metadata["action_expires_at"]).to be_present
      end

      it "keeps the destructive timestamp in the sublabel, not the title" do
        ev = ActionEvent.create!(user: user, name: "Coffee", timestamp: Time.zone.local(2026, 7, 28, 15, 10))
        btn = build([{ tool_name: :delete_event, payload: { id: ev.id }, span: [0, 0] }])[:action].buttons.first
        expect(btn["label"]).to eq("Delete Coffee")           # title = no timestamp
        expect(btn["label"]).not_to match(/Jul|:10|PM/)
        expect(btn["sublabel"]).to include("Jul 28")           # timestamp = detail
      end

      it "never renders a blank checkbox label" do
        action = build([{ tool_name: :create_chore, payload: { name: "Water the ficus" }, span: [0, 0] }])[:action]
        expect(action.buttons.first["label"]).to eq("Water the ficus")
        expect(action.buttons.first["label"]).to be_present
      end

      it "shows a full date/time (and notes) on a destructive delete row" do
        ev = ActionEvent.create!(user: user, name: "Strawberry Celsius", notes: "energy drink", timestamp: Time.zone.local(2026, 7, 28, 15, 10))
        action = build([{ tool_name: :delete_event, payload: { id: ev.id }, span: [0, 0] }])[:action]
        btn = action.buttons.first

        expect(btn["label"]).to eq("Delete Strawberry Celsius")
        expect(btn["sublabel"]).to include("Jul 28").and include("energy drink")
      end
    end

    # The confirm-card labels favour readability for a human reviewer: one
    # non-default detail per line (newlines, not a comma run), the kind chip
    # carries the verb (no "Delete:"/"Undo:" in the title), and symbols stand in
    # for obvious labels (@ location, 📋 list).
    describe "confirm-card labels" do
      let(:user) { create(:user) }
      let(:ctx)  { Buddy::ToolContext.new(user) }

      def label(name, payload)
        Buddy::Tools[name][:label].call(payload, ctx)
      end

      it "edit tools stack each field change on its own line (no comma run)" do
        out = label(:edit_chore, { chore: "Dishes", name: "Do Dishes", schedule: "every day" })
        expect(out[:title]).to eq("Dishes")
        expect(out[:sub]).not_to include(", ")
        expect(out[:sub].split("\n")).to include("name → Do Dishes", "schedule → every day")
      end

      it "list tools use a 📋 symbol for the list instead of a word-label" do
        add = label(:add_list_item, { item: "oat milk", list_name: "Groceries" })
        expect(add).to eq(title: "oat milk", sub: "📋 Groceries")
      end

      it "destructive tools KEEP the verb in the title (high-stakes, unmistakable)" do
        expect(label(:delete_event, { event: "Coffee" })[:title]).to eq("Delete Coffee")
        expect(label(:remove_list_item, { item: "oat milk", list_name: "Groceries" })[:title]).to eq("Remove oat milk")
      end

      it "log_event puts short notes on their own line, not glued with a dash" do
        out = label(:log_event, { name: "Coffee", notes: "oat milk, 8oz" })
        expect(out).to eq(title: "Coffee", sub: "oat milk, 8oz")
      end
    end
  end

  # The three confidence levels: level 1 fires + receipt chip (no checkbox),
  # level 2 fires immediately as a PRE-CHECKED undoable row, level 3 waits for a
  # tap. This covers level 2 (the new behavior) and the level-2/3 split.
  describe "levels" do
    let(:user) { create(:user) }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
    let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
    let!(:message) {
      convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hi", metadata: { "kind" => "buddy" })
    }

    before do
      user.update!(chore_household_id: household.id)
      allow(MonitorChannel).to receive(:broadcast_to)
    end

    def build(markers)
      Buddy::ProposalBuilder.create(user: user, byte_message: message.reload, markers: markers)
    end

    it "runs a level-2 tool immediately and marks the row executed + undoable" do
      result = build([{ tool_name: :log_event, payload: { name: "Coffee" } }])
      btn = result[:action].buttons.first

      expect(btn["status"]).to eq("executed")
      expect(btn["undoable"]).to be(true)
      expect(ActionEvent.where(user: user, name: "Coffee")).to exist
    end

    # A log is a record of the past. Prod: "I picked up lunch so I'm planning on
    # sitting down to eat it" was written into the history as a completed Lunch,
    # which is a fact in their record that never happened.
    it "tells the model a log is for what already happened, not what they're about to do" do
      description = Buddy::Tools[:log_event][:description]

      expect(description).to include("ONLY for something that ALREADY HAPPENED")
      expect(description).to include("I'm about to have lunch")
      expect(description).to include("The moment they say they DID it, log it then")
    end

    it "undoes a level-2 row when it's unchecked" do
      action = build([{ tool_name: :log_event, payload: { name: "Tea" } }])[:action]
      id = action.buttons.first["id"]

      Buddy::ProposalExecutor.undo!(action.id, id)

      expect(action.reload.buttons.first["status"]).to eq("undone")
      expect(ActionEvent.where(user: user, name: "Tea")).not_to exist
    end

    it "executes level-2 rows but leaves level-3 rows pending in the same checklist" do
      logged = ActionEvent.create!(user: user, name: "Coffee", timestamp: Time.current)
      result = build([
        { tool_name: :log_event,  payload: { name: "Water" } },                        # level 2
        { tool_name: :edit_event, payload: { event: "Coffee", name: "Decaf" } },       # level 3
      ])
      by_tool = result[:action].buttons.index_by { |b| b["tool_name"] }

      expect(by_tool["log_event"]["status"]).to eq("executed")
      expect(by_tool["edit_event"]["status"]).to eq("pending")
      # The level-3 rename has NOT happened yet — it waits for a tap.
      expect(logged.reload.name).to eq("Coffee")
    end

    # Prod message 1134: "Turn the fan to high, please" -> "Done. Fan's on high
    # now." and NOTHING else. The task really fired, but the receipt read
    # `ctx.proposal["payload"]`, and run_auto built a context without a proposal,
    # so it raised NoMethodError on nil, got swallowed, and the chip was skipped.
    # A level-1 action leaves no checklist row, so that prose was the only trace -
    # and prose is the one thing we can't take at face value.
    describe "the activity chip a level-1 action leaves behind" do
      let!(:fan) {
        Task.create!(
          user:          user,
          name:          "Fan High",
          listener:      "fan-high",
          code:          "// noop",
          enabled:       true,
          buddy_enabled: true,
          description:   "Sets the great room fan to high",
        )
      }

      def chip
        convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      end

      before { allow(::Jil).to receive(:trigger) }

      it "posts a chip naming the tool and the params it ran with" do
        result = build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])

        expect(result[:auto_ran]).to be(true)
        expect(chip).to be_present
        # Receipt in the body; which tool and which args as a separate footnote,
        # so the two can be styled apart instead of running together.
        expect(chip.body).to eq("Fired **Fan High**")
        expect(chip.metadata["detail"]).to eq("scope: fan-high")
        expect(chip.metadata["tool_name"]).to eq("trigger_jil_task")
      end

      # CSS puts a ✓ in front of every chip, and most receipts end with one of
      # their own - together they rendered "✓ Fired Fan High ✓".
      it "does not leave a second checkmark on the end of the receipt" do
        build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])

        expect(chip.body).not_to end_with("✓")
      end

      it "records the exact arguments on the chip for later inspection" do
        build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])

        expect(chip.metadata["tool_name"]).to eq("trigger_jil_task")
        expect(chip.metadata["payload"]).to include("task_name" => "Fan High", "scope" => "fan-high")
      end

      it "still posts a chip when the receipt itself blows up" do
        allow(Buddy::Tools[:trigger_jil_task][:receipt]).to receive(:call).and_raise("receipt exploded")

        build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])

        expect(chip).to be_present
        expect(chip.metadata["tool_name"]).to eq("trigger_jil_task")
      end

      # list_reminders returns nil on purpose: the rows it draws in the thread ARE
      # the output, so a chip would just sit above them saying it drew them. That
      # opt-out has to keep working.
      it "still honors a deliberate nil-receipt opt-out" do
        build([{ tool_name: :list_reminders, payload: {} }])

        expect(chip).to be_nil
      end
    end

    it "tiers are assigned as expected on the registry" do
      expect(Buddy::Tools[:log_event][:level]).to eq(2)
      expect(Buddy::Tools[:complete_chore][:level]).to eq(2)
      expect(Buddy::Tools[:add_list_item][:level]).to eq(2)
      expect(Buddy::Tools[:call_jil_function][:level]).to eq(1)
      expect(Buddy::Tools[:call_jil_function][:auto]).to be(true)
      expect(Buddy::Tools[:edit_event][:level]).to eq(3)
    end

    # Writing to a chore or a calendar runs on arrival and unticks back off. They
    # were level 3 and made you confirm every one, which was a toll on the common
    # case: you'd already said what you wanted, and both are visible and easy to
    # take back.
    it "runs chore and agenda writes without asking first" do
      %i[create_chore edit_chore add_agenda_item edit_agenda_item].each { |name|
        expect(Buddy::Tools[name][:level]).to eq(2), "#{name} should run on arrival"
      }
    end

    # A level-2 row promises an undo, and the row is a lie without one. Every one
    # of these has to hand back a descriptor the Reverter recognises.
    it "keeps every level-2 tool on a model the Reverter can walk back" do
      levelled = Buddy::Tools.all.select { |t| t[:level] == 2 }

      expect(levelled).to be_present
      expect(levelled.pluck(:name)).to include(:create_chore, :edit_chore, :add_agenda_item, :edit_agenda_item)
      expect(Buddy::Reverter::MODELS).to include("Chore", "AgendaItem")
    end
  end
end
