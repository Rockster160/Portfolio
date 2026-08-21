require "rails_helper"

RSpec.describe Buddy::EventSearch do
  # Buddy searching the whole ActionEvent log with the app's own query syntax,
  # rather than the name-fragment LIKE it used to be limited to.
  describe "searching" do
    let(:user)  { create(:user) }
    let(:other) { create(:user) }

    def event!(name, notes: nil, at: 1.hour.ago, owner: user)
      ActionEvent.create!(user: owner, name: name, notes: notes, timestamp: at)
    end

    describe ".call" do
      it "matches a bare word against the name OR the notes" do
        by_name  = event!("Strawberry Celsius")
        by_notes = event!("PrintStart", notes: "Wall_mount_phone_holder_v2")
        event!("Coffee")

        found = described_class.call(user: user, query: "phone")
        expect(found[:events]).to contain_exactly(by_notes)

        found = described_class.call(user: user, query: "celsius")
        expect(found[:events]).to contain_exactly(by_name)
      end

      it "honours field filters and exact matches" do
        exact = event!("PrintFailed", notes: "vase")
        event!("PrintFinish", notes: "vase")

        found = described_class.call(user: user, query: "name::PrintFailed")
        expect(found[:events]).to contain_exactly(exact)
      end

      it "honours negation and combines terms" do
        kept = event!("PrintFinish", notes: "phone holder")
        event!("PrintFinish", notes: "vase")

        found = described_class.call(user: user, query: "name::PrintFinish -notes:vase")
        expect(found[:events]).to contain_exactly(kept)
      end

      it "honours a timestamp bound inside the query" do
        old   = event!("Coffee", at: 40.days.ago)
        fresh = event!("Coffee", at: 2.days.ago)

        found = described_class.call(user: user, query: "Coffee timestamp>#{10.days.ago.to_date.iso8601}", days: 90)
        expect(found[:events]).to contain_exactly(fresh)
        expect(found[:events]).not_to include(old)
      end

      # `timestamp:>x` reads as one unknown `:>` operator and gets dropped, so the
      # bound silently stops applying. Accept the spelling instead of answering a
      # bounded question with unbounded results.
      it "accepts a colon before a comparison operator" do
        old   = event!("Coffee", at: 40.days.ago)
        fresh = event!("Coffee", at: 2.days.ago)

        found = described_class.call(user: user, query: "Coffee timestamp:>#{10.days.ago.to_date.iso8601}", days: 90)
        expect(found[:events]).to contain_exactly(fresh)
        expect(found[:events]).not_to include(old)
      end

      it "lists the most recent when no query is given" do
        older = event!("Coffee", at: 3.hours.ago)
        newer = event!("Water", at: 1.minute.ago)

        found = described_class.call(user: user)
        expect(found[:events]).to eq([newer, older])
      end

      # `query` rebuilds its SQL from `unscoped`, so ownership has to be
      # re-applied after it or a search reaches the whole household's log.
      it "never reaches another person's events" do
        mine = event!("Coffee")
        event!("Coffee", owner: other)

        found = described_class.call(user: user, query: "Coffee")
        expect(found[:events]).to contain_exactly(mine)
      end

      it "bounds the window by days and reports the full total behind the limit" do
        event!("Coffee", at: 40.days.ago)
        2.times { event!("Coffee", at: 1.day.ago) }

        found = described_class.call(user: user, query: "Coffee", days: 14, limit: 1)
        expect(found[:events].length).to eq(1)
        expect(found[:total]).to eq(2)
      end

      it "narrows to specific event names when the caller already knows them" do
        start = event!("PrintStart", notes: "vase")
        event!("Coffee")

        found = described_class.call(user: user, names: [:PrintStart])
        expect(found[:events]).to contain_exactly(start)
      end

      it "falls back to a plain match rather than failing on an unparseable query" do
        hit = event!("Coffee")

        expect(described_class.call(user: user, query: "Coffee ((")[:events]).to include(hit)
      end
    end

    describe ".rows" do
      it "leads with the id, since that's what delete_event and edit_event take" do
        event = event!("Strawberry Celsius", notes: "the pink one", at: Time.zone.parse("2026-08-05 14:42:00"))

        row = described_class.rows([event], user).first
        expect(row).to start_with("##{event.id} · Strawberry Celsius (the pink one) · ")
        expect(row).to include("8/5")
      end

      it "leaves the notes off when there aren't any" do
        event = event!("Coffee")

        expect(described_class.rows([event], user).first).to include("· Coffee ·")
      end
    end
  end

  # Byte finds an event by scoped search (even one not logged through him), then
  # removes it as an execute-immediately + undoable (Level 2) action.
  describe "search and delete together" do
    let(:user)   { create(:user) }
    let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
    let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
    end

    def build(markers)
      Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
    end

    def search(payload)
      Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:search_events],
        { call_id: "call_1", name: :search_events, arguments: payload },
        user: user, conversation: convo,
      )
    end

    it "search_events hands the matching events, with ids, back in the same turn" do
      ActionEvent.create!(user: user, name: "Strawberry Celsius", timestamp: 2.days.ago)
      ActionEvent.create!(user: user, name: "Coffee", timestamp: 1.day.ago)

      result = search(query: "celsius")

      expect(result[:status]).to eq(:answered)
      expect(result[:events].join("\n")).to include("Strawberry Celsius")
      expect(result[:how]).to include("`delete_event`")
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
    end

    # The guidance used to teach `[[propose: delete_event id=N]]`. Markers are
    # retired — Turn strips a stray one and logs it — so that instruction cost a
    # turn and left the event sitting there. Nothing that talks to the model may
    # teach it.
    it "search_events does not teach the retired marker protocol" do
      ActionEvent.create!(user: user, name: "Strawberry Celsius", timestamp: 2.days.ago)

      expect(search(query: "celsius")[:how]).not_to include("[[propose:")
    end

    it "delete_event by id is Level 2 - removes immediately, undoable, and restores on undo" do
      ev = ActionEvent.create!(user: user, name: "Strawberry Celsius", notes: "oops", timestamp: 2.days.ago)

      result = build([{ tool_name: :delete_event, payload: { id: ev.id }, span: [0, 0] }])
      btn = result[:action].buttons.first

      expect(btn["status"]).to eq("executed")   # fired immediately
      expect(btn["undoable"]).to be(true)        # pre-checked, uncheck-to-undo
      expect(ActionEvent.where(id: ev.id)).not_to exist

      Buddy::ProposalExecutor.undo!(result[:action].id, btn["id"])
      expect(ActionEvent.where(user: user, name: "Strawberry Celsius")).to exist # restored
    end

    it "registers delete_event at level 2" do
      expect(Buddy::Tools[:delete_event][:level]).to eq(2)
    end
  end
end
