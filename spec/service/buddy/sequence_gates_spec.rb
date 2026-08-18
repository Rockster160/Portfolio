require "rails_helper"

# A sequence with more than one gate in it, and the same sequence with the times
# taken out. Both have to hold their order.
#
# "Ask Chelsea if she wants Syrup for dinner in 5 minutes. If she says yes, wait
# 2 minutes and then add it to the agenda." — a wait, then a question put to
# someone else, then another wait, then a write. Every step of it is downstream
# of the one before, and the write is the one thing that must not happen early.
#
# It did happen early. build_steps hoisted every level-2 call to the front
# whatever position it came in, so the agenda item landed before Chelsea had
# been asked anything.
RSpec.describe "Buddy sequence gates" do
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

    # The whole bug in one assertion: nothing at all should have happened yet.
    it "asks nobody and books nothing while the first wait is running" do
      expect(relays).to be_empty
      expect(agenda).to be_empty
    end

    it "asks her when the five minutes are up, and still books nothing" do
      fire_timer!

      expect(relays.count).to eq(1)
      expect(agenda).to be_empty
    end

    it "starts the second wait on her answer rather than booking straight away" do
      fire_timer!
      answer!("yes please")

      expect(agenda).to be_empty
      expect(timer_gate.tool_input["deferred"]).to be_present
    end

    it "books it only once the second wait is up too" do
      fire_timer!
      answer!("yes please")
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

    it "asks her first and books nothing yet" do
      expect(relays.count).to eq(1)
      expect(agenda).to be_empty
    end

    it "books it on her answer" do
      answer!("yes please")

      expect(agenda.pluck(:name)).to eq(["Syrup for dinner"])
    end
  end

  # "IF she says yes" — the half of the sentence that used to be decorative.
  # Everything queued behind a question ran on any answer, because it was all
  # decided before the answer existed, so a no booked the dinner just the same.
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

    it "books nothing when she says no" do
      sequence
      answer!("no thanks")

      expect(agenda).to be_empty
    end

    # Silence would read as the sequence having finished, which is the same
    # failure in the other direction.
    it "says whose answer stopped it, and what didn't happen" do
      sequence
      answer!("no thanks")

      expect(last_said).to eq("#{her} said no, so I didn't go on to Syrup for dinner.")
    end

    # The third case. Guessing here is the whole bug, so it stops and asks
    # nothing further — the person can see what's outstanding and say the word.
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
