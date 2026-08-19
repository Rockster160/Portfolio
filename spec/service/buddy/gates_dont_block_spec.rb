require "rails_helper"

# Buddy stays usable while a sequence is parked.
#
# A wait can be an hour and a question put to another person can go unanswered
# for three days, so the thing that must never be true is that either one makes
# Buddy unavailable for everything else. This is the guarantee, written down:
# gates are inert rows, not locks, and nothing on the dispatch path consults
# them before running a turn.
RSpec.describe "Buddy while a sequence is waiting" do
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
    allow(::WebPushNotifications).to receive(:update_count)
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

  it "sets up the two kinds of wait this is about" do
    park_on_a_timer!
    park_on_a_person!

    expect(gates.pluck(:tool_name)).to contain_exactly(
      Buddy::ProposalBuilder::TIMER_GATE, Buddy::ProposalBuilder::RELAY_GATE
    )
  end

  it "still takes a new message and runs a turn for it" do
    park_on_a_timer!
    park_on_a_person!

    msg = say!("what's on today?")

    expect(msg).to be_present
    expect(Buddy::GPT::Turn).to have_received(:run!).with(msg)
  end

  # The turn lock is per-conversation and held only for the DURATION of a turn.
  # If a gate held it, or the queue behind one did, this is where it would show.
  it "holds no lock while the waits are pending" do
    park_on_a_timer!
    park_on_a_person!

    expect(ByteConversation.advisory_lock_exists?(Buddy::TurnDispatcher.lock_name(convo))).to be(false)
  end

  it "leaves the parked queues alone while other turns come and go" do
    park_on_a_timer!
    park_on_a_person!
    before_ids = gates.pluck(:id)

    3.times { |i| say!("message #{i}") }

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
