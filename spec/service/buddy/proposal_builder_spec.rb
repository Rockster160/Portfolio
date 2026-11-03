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
          summary:     "spec-only",
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

      it "creates a ByteAction with a row per surviving marker, discarding unknown tools", :aggregate_failures do
        markers = [
          { tool_name: :spec_noop,   payload: { thing: "one" },  span: [0, 0] },
          { tool_name: :spec_noop,   payload: { thing: "two" },  span: [0, 0] },
          { tool_name: :not_a_thing, payload: { thing: "nope" }, span: [0, 0] },
        ]
        result = described_class.create(user: user, byte_message: msg, markers: markers)
        action = result[:action]

        expect(action).to be_a(ByteAction)
        expect(action.multi_select).to be(true)
        expect(action.tool_name).to eq("buddy_proposals")
        expect(action.buttons.map { |b| b["label"] }).to eq(%w[one two])
        expect(result[:auto_ran]).to be(false)

        msg.reload
        expect(msg.metadata["kind"]).to eq("buddy_reply")
        expect(msg.metadata["action_request_id"]).to eq(action.request_id)
      end

      it "merges identical proposals via merge_key with total count", :aggregate_failures do
        markers = Array.new(3) { { tool_name: :spec_noop, payload: { thing: "same" }, span: [0, 0] } }
        action = described_class.create(user: user, byte_message: msg, markers: markers)[:action]

        expect(action.buttons.length).to eq(1)
        expect(action.buttons.first["count"]).to eq(3)
      end

      it "returns no action when no markers survive validation", :aggregate_failures do
        markers = [{ tool_name: :not_a_thing, payload: {}, span: [0, 0] }]
        result = described_class.create(user: user, byte_message: msg, markers: markers)
        expect(result[:action]).to be_nil
        expect(result[:auto_ran]).to be(false)
      end

      context "auto (no-confirm) tools" do
        before do
          Buddy::Tools.register(
            name:        :spec_auto,
            summary:     "spec-only",
            description: "auto tool used in specs",
            args:        { thing: { type: :string, required: true } },
            confirm:     ->(p, _) { { summary: "x", resolved: {} } },
            label:       ->(p, _) { p[:thing].to_s },
            execute:     ->(p, _) { { echoed: p[:thing] } },
            receipt:     ->(r, _) { "Handled #{r[:echoed]}" },
            auto:        true,
          )
        end

        # A level-1 action has no checklist row, so the chip is the only trace.
        it "runs immediately with an activity chip and no checklist, beside a confirm tool's checklist", :aggregate_failures do
          markers = [
            { tool_name: :spec_auto, payload: { thing: "reminder" }, span: [0, 0] },
            { tool_name: :spec_noop, payload: { thing: "c" }, span: [0, 0] },
          ]

          result = nil
          expect {
            result = described_class.create(user: user, byte_message: msg, markers: markers)
          }.to change { convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").count }.by(1)

          expect(result[:auto_ran]).to be(true)
          expect(result[:action].buttons.map { |b| b["label"] }).to eq(["c"])
          chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
          expect(chip.body).to eq("Handled reminder")
          expect(chip.metadata["tool_name"]).to eq("spec_auto")
          expect(chip.direction).to eq("inbound")

          only_auto = described_class.create(user: user, byte_message: msg, markers: markers.first(1))
          expect(only_auto[:action]).to be_nil
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
      end

      it "degrades to a note when the reissued proposal can't rebuild", :aggregate_failures do
        result = nil
        expect {
          result = Buddy::ProposalBuilder.reissue(
            user: user, conversation: convo,
            button: { "tool_name" => "totally_unknown_tool", "payload" => { "x" => "1" } }
          )
        }.to change { convo.byte_messages.count }.by(1)

        expect(result[:action]).to be_nil
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

      # The expiry rides on the message metadata so the client can grey out a
      # stale row instead of letting the person tap into nothing.
      it "gives a Buddy checklist a long TTL, a real label, and no hint unless the tool offers one", :aggregate_failures do
        action = build([{ tool_name: :create_chore, payload: { name: "Water the ficus" }, span: [0, 0] }])[:action]

        expect(action.expires_at).to be > 1.day.from_now
        expect(action).to be_pending
        expect(action.byte_message.reload.metadata["action_expires_at"]).to be_present
        expect(action.buttons.first["label"]).to eq("Water the ficus")
        expect(action.buttons.first["hint"]).to be_nil
      end

      it "keeps a destructive row's timestamp and notes in the sublabel, not the title", :aggregate_failures do
        ev = ActionEvent.create!(user: user, name: "Strawberry Celsius", notes: "energy drink", timestamp: Time.zone.local(2026, 7, 28, 15, 10))
        btn = build([{ tool_name: :delete_event, payload: { id: ev.id }, span: [0, 0] }])[:action].buttons.first

        expect(btn["label"]).to eq("Delete Strawberry Celsius")
        expect(btn["label"]).not_to match(/Jul|:10|PM/)
        expect(btn["sublabel"]).to include("Jul 28").and include("energy drink")
      end

      # The `hint` slot is the only place on a row that renders markdown, so it
      # is the only place a link can go.
      it "carries a tool's hint onto the row" do
        Buddy::Tools.register(
          name:        :spec_hinted,
          summary:     "spec-only",
          description: "hint plumbing",
          args:        { thing: { type: :string, required: true } },
          confirm:     ->(p, _) { { summary: "Do #{p[:thing]}?", resolved: {} } },
          label:       ->(p, _) { p[:thing].to_s },
          hint:        ->(p, _) { { "tap" => "[Read it](/emails/#{p[:thing]})", "done" => "Read" } },
          execute:     ->(_p, _) { {} },
          receipt:     ->(_r, _) { "done" },
        )
        btn = build([{ tool_name: :spec_hinted, payload: { thing: "7" }, span: [0, 0] }])[:action].buttons.first

        expect(btn["hint"]["tap"]).to eq("[Read it](/emails/7)")
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

    it "runs a level-2 tool immediately as an undoable row, and undoes it when unchecked", :aggregate_failures do
      action = build([{ tool_name: :log_event, payload: { name: "Coffee" } }])[:action]
      btn = action.buttons.first

      expect(btn["status"]).to eq("executed")
      expect(btn["undoable"]).to be(true)
      expect(ActionEvent.where(user: user, name: "Coffee")).to exist

      Buddy::ProposalExecutor.undo!(action.id, btn["id"])

      expect(action.reload.buttons.first["status"]).to eq("undone")
      expect(ActionEvent.where(user: user, name: "Coffee")).not_to exist
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

    # A level-1 action leaves no checklist row, so the chip is the only trace
    # that it ran, and must survive a receipt that needs the proposal or raises.
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

      # CSS puts a ✓ in front of every chip, so the receipt must not end on one.
      it "posts a chip naming the tool and the exact params it ran with", :aggregate_failures do
        result = build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])

        expect(result[:auto_ran]).to be(true)
        expect(chip.body).to include("Fan High")
        expect(chip.body).not_to end_with("✓")
        expect(chip.metadata["detail"]).to eq("scope: fan-high")
        expect(chip.metadata["tool_name"]).to eq("trigger_jil_task")
        expect(chip.metadata["payload"]).to include("task_name" => "Fan High", "scope" => "fan-high")
        # Most tasks just do the thing, and say nothing.
        expect(result[:answers]).to eq([])
      end

      # A fired scope hands back every task it ran, each one's execution already
      # finished. A function answering with a flag is not saying a word.
      it "carries up what the tasks it fired actually said, but not a bare flag", :aggregate_failures do
        allow(::Jil).to receive(:trigger).and_return([fan])
        allow(fan).to receive(:last_message).and_return("Fan's on high in the great room")
        expect(build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])[:answers]).to eq(["Fan's on high in the great room"])

        allow(fan).to receive(:last_message).and_return(true)
        expect(build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])[:answers]).to eq([])
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
  end
end
