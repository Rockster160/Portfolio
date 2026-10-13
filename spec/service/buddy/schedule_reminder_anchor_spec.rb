require "rails_helper"

# "Half an hour before any interview", "ten days before anybody's birthday",
# "after my interview today" - a reminder hung off something upcoming rather
# than a clock time, so it follows the thing when the thing moves.
RSpec.describe "schedule_reminder anchored to what's coming up" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }
  let(:agenda) { create(:agenda, user: user, name: "Mine") }

  let(:noon) { Time.current.tomorrow.change(hour: 12, min: 0) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def interview!(start_at: noon)
    create(
      :agenda_item,
      agenda: agenda, name: "Interview: Bluestaq", kind: :event,
      start_at: start_at, end_at: start_at + 1.hour
    )
  end

  def ask(payload)
    Buddy::ProposalBuilder.create(
      user: user, byte_message: msg,
      markers: [{ tool_name: :schedule_reminder, payload: payload, span: [0, 0] }]
    )
  end

  it "hangs a standing rule off the next one and keeps the expression" do
    interview!

    expect {
      ask(text: "What Bluestaq is like and what to expect", anchor: "agenda:interview-30m", kind: "prompt")
    }.to change { BuddyReminder.where(user: user).count }.by(1)

    reminder = BuddyReminder.where(user: user).last
    expect(reminder.fire_at).to be_within(1.second).of(noon - 30.minutes)
    expect(reminder.anchor).to eq("agenda:interview-30m")
    expect(reminder.kind).to eq("prompt")
    expect(reminder).to be_recurring
  end

  it "creates the key, because the key is the subscription" do
    interview!

    ask(text: "Read up on them", anchor: "agenda:interview-30m")

    expect(Anchor.keys_for(user)).to include("agenda:interview")
  end

  it "pins one to a single item for an ask about today" do
    item = interview!

    ask(text: "Start the laundry", anchor: "agenda:end[#{item.id}]+10m")

    reminder = BuddyReminder.where(user: user).last
    expect(reminder.fire_at).to be_within(1.second).of(noon + 1.hour + 10.minutes)
    expect(reminder).not_to be_recurring
  end

  it "parks a standing rule when there is nothing to hang it off yet" do
    ask(text: "Read up on them", anchor: "agenda:interview-30m")

    reminder = BuddyReminder.where(user: user).last
    expect(reminder.anchor).to eq("agenda:interview-30m")
    expect(reminder.fire_at).to be_nil
  end

  it "sets nothing when a pinned one names an occurrence that isn't there" do
    expect {
      ask(text: "Read up on them", anchor: "agenda:interview[404]-30m")
    }.not_to(change { BuddyReminder.where(user: user).count })
  end

  it "follows the interview when the interview moves" do
    item = interview!
    ask(text: "Read up on them", anchor: "agenda:interview-30m")
    reminder = BuddyReminder.where(user: user).last

    item.update!(start_at: noon + 3.hours, end_at: noon + 4.hours)
    AnchorFeeder.call(user)

    expect(reminder.reload.fire_at).to be_within(1.second).of(noon + 2.hours + 30.minutes)
  end

  # The row used to show the minute it currently worked out to, which is a true
  # sentence about the wrong thing: it reads as a one-off on Thursday, where
  # what is set is every interview there will ever be.
  describe "how it reads in the list" do
    def row_for(reminder)
      Buddy::ReminderPresenter.rows(user, include_off: true).find { |r| r[:record_id] == reminder.id }
    end

    it "says the rule, with the time it works out to after it" do
      interview!
      ask(text: "Read up on them", anchor: "agenda:interview-30m")

      row = row_for(BuddyReminder.where(user: user).last)
      expect(row[:sublabel]).to start_with("30 minutes before the next interview")
      expect(row[:sublabel]).to include("next")
    end

    it "still reads as something that is set when nothing is booked" do
      ask(text: "Read up on them", anchor: "agenda:interview-30m")

      row = row_for(BuddyReminder.where(user: user).last)
      expect(row[:sublabel]).to eq("30 minutes before the next interview · nothing on it yet")
    end

    # There is no clock to edit, and a repeat editor over the top of an anchor
    # is an invitation to overwrite it.
    it "hands the editor no time and no repeat rule" do
      interview!
      ask(text: "Read up on them", anchor: "agenda:interview-30m")

      row = row_for(BuddyReminder.where(user: user).last)
      expect(row[:at]).to be_nil
      expect(row[:anchored]).to be(true)
      expect(row[:freq]).to be_nil
    end
  end

  it "is over rather than instantly due once the interview has been" do
    item = interview!
    ask(text: "Read up on them", anchor: "agenda:interview[#{item.id}]-30m")
    reminder = BuddyReminder.where(user: user).last

    item.update!(start_at: 2.days.ago, end_at: 2.days.ago + 1.hour)
    AnchorFeeder.call(user)

    expect(reminder.reload.cancelled_at).to be_present
  end
end
