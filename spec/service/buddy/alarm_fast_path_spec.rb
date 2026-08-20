require "rails_helper"

# Typing "alarm" rings one. No model turn, no tool call, no waiting.
#
# Same reasoning as the timer fast path next door: a round trip costs several
# seconds, and they're several seconds during which the model might not call the
# tool at all. On a countdown that's most of a short timer. On this it's the
# whole point — the word is what you type when you want a noise NOW.
RSpec.describe "Buddy alarm fast path" do
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::WebPushNotifications).to receive(:update_count)
    allow(BuddyDeliverWorker).to receive(:perform_async)
    convo.update_columns(buddy_theme: "byte")
  end

  def say!(body)
    ByteMessageIntake.call(user: user, conversation: convo, body: body)
  end

  def alarms
    Timer.where(user_id: user.id).select { |t| Buddy::Alarms.alarm?(t) }
  end

  def chips
    convo.byte_messages.where(direction: :inbound).select { |m| m.metadata["kind"] == "buddy_activity" }
  end

  describe "the bare word" do
    it "rings one" do
      say!("alarm")

      expect(alarms.length).to eq(1)
    end

    it "never reaches the model" do
      say!("alarm")

      expect(BuddyDeliverWorker).not_to have_received(:perform_async)
    end

    it "still posts their own bubble" do
      message = say!("alarm")

      expect(message.body).to eq("alarm")
      expect(message.direction).to eq("outbound")
    end

    it "says so in the thread" do
      say!("alarm")

      expect(chips.last.body).to include("alarm")
      expect(chips.last.metadata["tool_name"]).to eq("alarm")
      expect(chips.last.metadata["source"]).to eq("fast_path")
    end

    # An alarm IS a timer with the flag on it — that's what makes the ringing
    # loop, the push, the acknowledge tap and the offline queue all work already.
    it "is a real alarm rather than a plain countdown" do
      say!("alarm")

      expect(Buddy::Alarms.alarm?(alarms.first)).to be(true)
    end

    # It's flagged `quick` so the countdown underneath knows it has nothing left
    # to announce when it reaches zero.
    it "is marked as a ring that has already announced itself" do
      say!("alarm")

      expect(Buddy::Alarms.quick?(alarms.first)).to be(true)
    end

    # The chip is the only line this produces, so it's the one that has to reach
    # somebody who isn't looking at the app.
    it "pushes" do
      say!("alarm")

      expect(WebPushNotifications).to have_received(:send_to_byte).with(hash_including(title: "⏰ Alarm"))
    end

    # Prod 4062 ("Byte sounded the alarm ⏰") and 4063 ("⏰ Alarm") were the same
    # event twice, 5.6 seconds apart.
    it "says it once, not once now and once when the countdown lands" do
      say!("alarm")
      Buddy::Timers.on_fired(alarms.first.tap { |t| t.update!(fired_at: Time.current) })

      expect(chips.length).to eq(1)
      expect(convo.byte_messages.where(direction: :inbound).map(&:body)).to eq([chips.first.body])
    end

    it "takes the punctuation people actually type" do
      ["alarm", "ALARM", "Alarm!", "alarm.", " alarm ", "alarm!!"].each do |text|
        expect(Buddy::Alarms.bare_request?(text)).to be(true), "expected #{text.inspect} to ring"
      end
    end
  end

  # The one thing this must never do is make a noise in the room in answer to a
  # request to make one at seven o'clock.
  describe "anything longer" do
    it "leaves a time to the model" do
      [
        "alarm in 20 minutes",
        "alarm at 7",
        "set an alarm for 6:30",
        "alarm when the washer finishes",
        "cancel the alarm",
        "what alarms do I have",
        "alarm?",
      ].each do |text|
        expect(Buddy::Alarms.bare_request?(text)).to be(false), "expected #{text.inspect} to go to the model"
      end
    end

    it "actually hands one of those on rather than ringing" do
      say!("alarm in 20 minutes")

      expect(alarms).to be_empty
      expect(BuddyDeliverWorker).to have_received(:perform_async)
    end
  end

  # Setting one off from somewhere else — the Mac CLI, a cron, a Jil bash step —
  # without the word that did it turning up in the thread as though they'd said
  # it. `hidden` is the same flag the quick-action chips and the daily audit
  # already ride on: the row still exists (the ring hangs off it), it just isn't
  # anything anyone reads.
  describe "triggering one without a visible message" do
    def say_hidden!(body)
      ByteMessageIntake.call(user: user, conversation: convo, body: body, metadata: { hidden: true })
    end

    it "still rings" do
      say_hidden!("alarm")

      expect(alarms.length).to eq(1)
    end

    it "keeps the flag on their message, which the client drops on sight" do
      expect(say_hidden!("alarm").metadata["hidden"]).to be(true)
    end

    # Not the alarm word specifically — anything the thread accepts can come in
    # this way. `fake!` because the suite runs Sidekiq inline and a five-minute
    # countdown would have TimerFireWorker reschedule itself forever.
    it "works the same for a timer" do
      Sidekiq::Testing.fake! { say_hidden!("5m pasta") }

      expect(Timer.where(user_id: user.id).count).to eq(1)
      expect(convo.byte_messages.where(direction: :outbound).last.metadata["hidden"]).to be(true)
    end

    # What Buddy SAYS is not hidden — only the words that asked for it. The
    # chip is the whole point of the thing still being visible.
    it "leaves the chip it produced alone" do
      say_hidden!("alarm")

      expect(chips.last.metadata["hidden"]).to be_nil
    end
  end

  # A claude or bash thread has no companion behind it, and "alarm" there is
  # something being typed at a shell.
  it "only fires on a Buddy thread" do
    shell = user.byte_conversations.create!(mode: :bash, name: "Terminal")

    ByteMessageIntake.call(user: user, conversation: shell, body: "alarm")

    expect(alarms).to be_empty
  end

  # A failure to ring must not swallow the message — the bubble is already
  # posted, and losing what they typed is worse than a missing alarm.
  it "still returns their message when ringing blows up" do
    allow(Buddy::Timers).to receive(:create!).and_raise("boom")
    allow(Buddy::Errors).to receive(:report)

    expect(say!("alarm")&.body).to eq("alarm")
    expect(Buddy::Errors).to have_received(:report)
  end
end
