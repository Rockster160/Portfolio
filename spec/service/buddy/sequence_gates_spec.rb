require "rails_helper"

RSpec.describe "Buddy sequence gates" do
  # A wait, a question to someone else, another wait, then a write: every step
  # is downstream of the one before, and a level-2 write must not be hoisted
  # in front of the gates that precede it.
  describe "gates" do
    let(:user)       { create(:user) }
    let(:partner)    { create(:user) }
    let(:her)        { partner.username } # first_name == username for factory users
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
    let!(:convo)     {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    # The suite runs Sidekiq inline, so a countdown started here would fire during
    # the example and every assertion about what's still waiting would really be
    # an assertion about how fast the spec ran.
    around { |ex| Sidekiq::Testing.fake! { ex.run } }

    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(Buddy::CompanionRelay).to receive(:deliver!)
      allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
      TimerFireWorker.clear
      ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
      user.update!(chore_household_id: household.id)
      partner.update!(chore_household_id: household.id)
      convo.update_columns(buddy_theme: "byte")
    }

    def ask(body, calls)
      inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
      Buddy::GPT::Turn.run!(inbound, client: FakeBuddyClient.new([{ tool_calls: calls }, { text: "On it." }]))
    end

    def wait_for(seconds, call_id:)
      { name: :set_timer, call_id: call_id, arguments: { "seconds" => seconds, "then_continue" => true } }
    end

    def ask_chelsea(call_id:, continue_if: nil)
      args = {
        "to"          => her,
        "question"    => "Do you want syrup for dinner?",
        "await_reply" => true,
        "var"         => "hers",
      }
      args["continue_if"] = continue_if if continue_if
      { name: :ask_partner, call_id: call_id, arguments: args }
    end

    def add_dinner(call_id:)
      {
        name:      :add_agenda_item,
        call_id:   call_id,
        arguments: { "title" => "Syrup for dinner", "at" => Time.current.tomorrow.change(hour: 18).iso8601 },
      }
    end

    def timer_gate
      ByteAction.where(user_id: user.id, tool_name: Buddy::ProposalBuilder::TIMER_GATE, state: :pending).order(:id).last
    end

    def relay_gate
      ByteAction.where(user_id: user.id, tool_name: Buddy::ProposalBuilder::RELAY_GATE, state: :pending).order(:id).last
    end

    def fire_timer!
      Buddy::ProposalBuilder.resume_after!(Timer.find(timer_gate.tool_input["timer_id"]))
    end

    def answer!(text)
      relay = BuddyRelay.find(relay_gate.tool_input["relay_id"])
      relay.update!(answer: text, answered_at: Time.current)
      Buddy::ProposalBuilder.resume_after_reply!(relay)
    end

    def agenda
      AgendaItem.where(name: "Syrup for dinner")
    end

    def relays
      BuddyRelay.where(from_user_id: user.id)
    end

    describe "with the times in it" do
      before {
        ask(
          "Ask #{her} if she wants Syrup for dinner in 5 minutes. " \
          "If she says yes, wait 2 minutes and then add it to the agenda.",
          [
            wait_for(300, call_id: "c1"),
            ask_chelsea(call_id: "c2"),
            wait_for(120, call_id: "c3"),
            add_dinner(call_id: "c4"),
  ],
        )
      }

      it "releases each step only when the gate before it opens", :aggregate_failures do
        expect(relays).to be_empty
        expect(agenda).to be_empty

        fire_timer!
        expect(relays.count).to eq(1)
        expect(agenda).to be_empty

        answer!("yes please")
        expect(agenda).to be_empty
        expect(timer_gate.tool_input["deferred"]).to be_present

        fire_timer!
        expect(agenda.pluck(:name)).to eq(["Syrup for dinner"])
      end
    end

    # Same sentence with every time phrase taken out. One gate instead of three,
    # and the ordering still has to hold.
    describe "with the times taken out" do
      before {
        ask(
          "Ask #{her} if she wants Syrup for dinner. If she says yes, add it to the agenda.",
          [ask_chelsea(call_id: "c1"), add_dinner(call_id: "c2")],
        )
      }

      it "asks her first and books it on her answer", :aggregate_failures do
        expect(relays.count).to eq(1)
        expect(agenda).to be_empty

        answer!("yes please")

        expect(agenda.pluck(:name)).to eq(["Syrup for dinner"])
      end
    end

    # `continue_if` decides on the answer once it exists.
    describe "when the follow-up is conditional on her answer" do
      def sequence
        ask(
          "Ask #{her} if she wants Syrup for dinner. If she says yes, add it to the agenda.",
          [ask_chelsea(call_id: "c1", continue_if: "yes"), add_dinner(call_id: "c2")],
        )
      end

      def last_said
        convo.byte_messages.where(direction: :inbound).order(:created_at).last.body
      end

      it "books it when she says yes" do
        sequence
        answer!("yes please")

        expect(agenda.pluck(:name)).to eq(["Syrup for dinner"])
      end

      # Silence would read as the sequence having finished.
      it "books nothing when she says no, and says what didn't happen", :aggregate_failures do
        sequence
        answer!("no thanks")

        expect(agenda).to be_empty
        expect(last_said).to include(her, "Syrup for dinner")
      end

      # Neither yes nor no: it stops rather than guess.
      it "refuses to guess at an answer that is neither" do
        sequence
        answer!("maybe, what time?")

        expect(agenda).to be_empty
        expect(last_said).to include("I couldn't tell whether that was a yes")
      end

      # No condition means what it always meant.
      it "still books it either way when no condition was given" do
        ask(
          "Ask #{her} if she wants Syrup for dinner, then put it on the agenda",
          [ask_chelsea(call_id: "c1"), add_dinner(call_id: "c2")],
        )
        answer!("no thanks")

        expect(agenda.pluck(:name)).to eq(["Syrup for dinner"])
      end
    end

    # A level-2 write with no wait in front of it still runs on arrival — that's
    # what level 2 IS, and the hoist that makes it happen is only blocked by a
    # wait the model put earlier.
    it "still runs a write that nothing is waiting on" do
      ask("Put syrup for dinner on the agenda and tell #{her}", [
        add_dinner(call_id: "c1"),
        { name: :message_partner, call_id: "c2", arguments: { "to" => her, "message" => "Syrup tomorrow." } },
      ])

      expect(agenda.pluck(:name)).to eq(["Syrup for dinner"])
    end
  end

  # Buddy stays usable while a sequence is parked: gates are inert rows, not
  # locks, and nothing on the dispatch path consults them before running a turn.
  describe "what a gate doesn't block" do
    let(:user)       { create(:user) }
    let(:partner)    { create(:user) }
    let(:her)        { partner.username }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
    let!(:convo)     {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }
    let!(:her_convo) {
      partner.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(::Jil).to receive(:trigger).and_return(true)
      allow(Buddy::Compactor).to receive(:should_compact?).and_return(false)
      allow(Buddy::GPT::Turn).to receive(:run!).and_return(true)
      # Stubbing the turn leaves the background settle running, and these fixtures
      # are long enough to clear its threshold. This spec is about sequence
      # parking; the topic distiller reaching for a model here is incidental.
      allow(Buddy::TopicState).to receive(:settle!)
      ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
      user.update!(chore_household_id: household.id)
      partner.update!(chore_household_id: household.id)
    end

    def message!(body="ok")
      convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: body, delivered_at: Time.current)
    end

    def build!(markers)
      Buddy::ProposalBuilder.create(user: user, byte_message: message!, markers: markers)
    end

    # An hour-long wait with something queued behind it.
    def park_on_a_timer!
      Sidekiq::Testing.fake! {
        build!([
          { tool_name: :set_timer, payload: { seconds: 3600, label: "printer", then_continue: true } },
          { tool_name: :message_partner, payload: { to: her, message: "preheating now" } },
        ])
      }
    end

    # The same wait with NOTHING behind it: `then_continue` passed, empty queue.
    def wait_on_nothing!
      Sidekiq::Testing.fake! {
        build!([{ tool_name: :set_timer, payload: { seconds: 120, label: "nap sound", then_continue: true } }])
      }
    end

    describe "a wait holding nothing" do
      it "reports itself so the reply above it can be taken down, and opens no gate" do
        result = nil

        expect { result = wait_on_nothing! }.not_to change(gates, :count)
        expect(result[:empty_wait]).to be(true)
      end

      it "says nothing of the kind when the queue is real" do
        expect(park_on_a_timer![:empty_wait]).to be(false)
      end
    end

    # A question to someone who may never answer.
    def park_on_a_person!
      build!([
        { tool_name: :ask_partner, payload: { to: her, question: "Dinner?", await_reply: true, var: "hers" } },
        { tool_name: :message_partner, payload: { to: her, message: "she wants {{hers}}" } },
      ])
    end

    def gates
      ByteAction.where(
        tool_name: [Buddy::ProposalBuilder::TIMER_GATE, Buddy::ProposalBuilder::RELAY_GATE],
        state:     :pending,
      )
    end

    def say!(body)
      ByteMessageIntake.new(user: user, conversation: convo, body: body).call
    end

    # The turn lock is per-conversation and held only for the DURATION of a turn.
    it "takes new messages and runs turns, holding no lock and leaving the parked queues alone", :aggregate_failures do
      park_on_a_timer!
      park_on_a_person!
      before_ids = gates.pluck(:id)

      expect(gates.pluck(:tool_name)).to contain_exactly(
        Buddy::ProposalBuilder::TIMER_GATE, Buddy::ProposalBuilder::RELAY_GATE
      )
      expect(ByteConversation.advisory_lock_exists?(Buddy::TurnDispatcher.lock_name(convo))).to be(false)

      msg = say!("what's on today?")
      2.times { |i| say!("message #{i}") }

      expect(msg).to be_present
      expect(Buddy::GPT::Turn).to have_received(:run!).with(msg)
      expect(gates.pluck(:id)).to match_array(before_ids)
    end

    # A second conversation is the more common shape — the wait is in one thread
    # and they carry on in another.
    it "doesn't touch a different conversation at all" do
      park_on_a_person!
      other = user.byte_conversations.create!(mode: :buddy, name: "Other", last_message_at: Time.current)

      msg = ByteMessageIntake.new(user: user, conversation: other, body: "hey").call

      expect(Buddy::GPT::Turn).to have_received(:run!).with(msg)
    end

    # The fast paths that bypass the model entirely have to keep working too.
    # `fake!` because starting a countdown schedules its own fire job, which the
    # suite would otherwise run inline and immediately.
    it "still serves a timer off the fast path" do
      park_on_a_person!

      Sidekiq::Testing.fake! {
        expect { say!("5m pasta") }.to change { user.timers.count }.by(1)
      }
    end
  end
end
