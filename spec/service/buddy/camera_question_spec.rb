require "rails_helper"

# Asking to SEE what a camera has, and getting told it can't be pulled up.
#
# The line is NOT the tense. "When was the last time somebody was at the door?"
# is answered by the time of the last alert; what needs a camera is a request
# for the PICTURE, or for "who" (a face only comes off a frame), or for what's
# out there right now.
RSpec.describe "a camera question that called nothing" do
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  let!(:last_seen) {
    Task.create!(
      user:          user,
      name:          "Camera Last Seen",
      listener:      'function("Camera" TAB ["doorbell" "driveway"]("doorbell") BR "Event" TAB ["person"])::String',
      code:          "// noop",
      enabled:       true,
      buddy_enabled: true,
      description:   "Reports the last thing a camera saw",
    )
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def user_says(text)
    convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: text)
  end

  def run(rounds, text:)
    client = FakeBuddyClient.new(rounds)
    Buddy::GPT::Turn.run!(user_says(text), client: client)
    client
  end

  # The reply, which is created up front and updated in place — so it's the
  # FIRST inbound row, not the last. A turn that calls a tool also files a
  # "Called X" receipt chip behind it.
  def reply
    convo.byte_messages.where(direction: :inbound).order(:id).first
  end

  def nudge_sent(client)
    return nil if client.calls.length < 2

    client.calls[1].input.last[:content]
  end

  def nudged?(client)
    nudge_sent(client).to_s.include?("They asked to SEE something")
  end

  def nudged_on?(question)
    nudged?(run([{ text: "Hm, I can't pull that up from here." }, { text: "ok" }], text: question))
  end

  it "sends a request for the picture, a who, or a look right now back to look", :aggregate_failures do
    [
      "Can you show me the last person that came to the door?",
      "Show me the last person who was at the door",
      "Show me the last person that rang the doorbell",
      "Who was at the door yesterday morning?",
      "Who rang the doorbell?",
      "Pull up the driveway camera",
      "Send me a picture of the front door",
      "What's going on in the backyard?",
      "What’s happening out on the porch?",
      "Anything going on in the driveway?",
      "Take a look at the backyard for me",
      "Check the driveway",
      "What do you see on the porch?",
    ].each { |question| expect(nudged_on?(question)).to be(true), question }
  end

  # The nouns carry the "right now" arm - the verbs match half of everything.
  # A question about WHEN is answered by the time it happened.
  it "leaves questions about when, and about things that aren't cameras, alone", :aggregate_failures do
    [
      "What's going on with the garage door?",
      "Check the laundry when you get a sec",
      "What's happening today?",
      "When was the last time somebody was at the door?",
      "When was the last time somebody came to the door?",
      "What about just saw a person?",
      "Has anyone been to the door today?",
      "Did the doorbell ring while I was out?",
      "Let me know the next time somebody comes to the door",
      "Add doorbell batteries to the shopping list",
    ].each { |question| expect(nudged_on?(question)).to be(false), question }
  end

  # A refusal is exempted from the false-claim guard on purpose (DENIAL_RX), so
  # this needs its own arm.
  it "catches the refusal shape, names the function, and keeps the answer from the retry" do
    client = run(
      [
        { text: "Hm, I can't show the person itself from here." },
        { tool_calls: [{ name: :call_jil_function, arguments: { "name" => "Camera Last Seen" } }] },
        { text: "Someone came by at 3:30 this afternoon." },
      ],
      text: "Show me the last person that rang the doorbell",
    )

    expect(nudged?(client)).to be(true)
    expect(nudge_sent(client)).to include("Camera Last Seen")
    expect(reply.body).to eq("Someone came by at 3:30 this afternoon.")
  end

  describe "what it must leave alone" do
    it "says nothing when a camera function did run" do
      client = run(
        [
          { tool_calls: [{ name: :call_jil_function, arguments: { "name" => "Camera Snapshot" } }] },
          { text: "Posted a live doorbell frame." },
        ],
        text: "Show me the last person that rang the doorbell",
      )

      expect(nudged?(client)).to be(false)
    end

    it "leaves a self-initiated notification alone" do
      seed = convo.byte_messages.create!(
        user:      user,
        direction: :outbound,
        state:     :sent,
        body:      "[nothing was said to you - this fired on its own] 🔔 Someone's at the doorbell.",
        metadata:  { "self_initiated" => true },
      )
      client = FakeBuddyClient.new([{ text: "🔔 Someone's at the doorbell." }, { text: "ok" }])
      Buddy::GPT::Turn.run!(seed, client: client)

      expect(nudged?(client)).to be(false)
    end

    # Pointing at a function that isn't offered would be telling it to invent a
    # name, so no camera function (or an opted-out one) means no nudge.
    it "stays quiet when this person has no buddy-enabled camera function" do
      last_seen.update!(buddy_enabled: false)
      expect(nudged_on?("Show me the last person that rang the doorbell")).to be(false)

      last_seen.destroy!
      expect(nudged_on?("Show me the last person that rang the doorbell")).to be(false)
    end
  end
end
