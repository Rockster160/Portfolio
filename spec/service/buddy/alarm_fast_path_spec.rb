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
