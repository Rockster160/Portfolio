require "rails_helper"

# Asking to SEE what a camera has, and getting told it can't be pulled up.
#
# The line is NOT the tense, and getting that wrong the first time is what this
# file is mostly here to pin down. "When was the last time somebody was at the
# door?" is a question about a time, and the time of the last alert answers it —
# no camera needs consulting to say when the doorbell rang. What needs a camera
# is the request for the PICTURE:
#
#   3789 "Show me the last person that rang the doorbell"
#     → "Hm, I can't show the person itself from here."
#   3728 "Can you show me the last person that came to the door?"
#     → "Hm, I can't pull up a live camera view from here."
#   3751 "Show me the last person who was at the door"
#     → "Hm, I can't pull up the person itself from here."
#
# `Camera Last Seen` was in the index for all three and has never run once.
#
# "Who" belongs with them: identifying a person is a question about a face, and
# a face only comes off a frame. "Who was at the door yesterday morning" wants
# the picture without ever saying so.
#
# Two task-description rewrites were aimed here before the nudge, plus
# `call_jil_function`'s own "never tell them you can't check something that has
# a function for it". All landed; 3790 broke the newest one 26 minutes later.
RSpec.describe "a camera question that called nothing" do
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  # Mirrors prod 484, the one that has never run.
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

  # The picture requests that were refused, verbatim, plus the two shapes that
  # ask for a face without naming one.
  describe "asking to see" do
    [
      "Can you show me the last person that came to the door?",  # 3728
      "Show me the last person who was at the door",             # 3751
      "Show me the last person that rang the doorbell",          # 3789
      "Who was at the door yesterday morning?",
      "Who rang the doorbell?",
      "Pull up the driveway camera",
      "Send me a picture of the front door",
    ].each do |question|
      it "sends it back to look, on #{question.inspect}" do
        client = run(
          [{ text: "Hm, I can't pull that up from here." }, { text: "A courier, about 3:30." }],
          text: question,
        )

        expect(nudged?(client)).to be(true)
      end
    end
  end

  # THE distinction, and the one this got wrong first time round. A question
  # about WHEN something happened is answered by the time it happened. There is
  # no picture in it, so sending it to a camera would be spending a round to
  # answer a question that was already answered — and worse, would push a frame
  # at someone who asked for a timestamp.
  describe "asking what happened" do
    [
      "When was the last time somebody was at the door?",   # 3787
      "When was the last time somebody came to the door?",  # 3735
      "What about just saw a person?",                      # 3737
      "Has anyone been to the door today?",
      "Did the doorbell ring while I was out?",
    ].each do |question|
      it "leaves it alone, on #{question.inspect}" do
        client = run(
          [{ text: "The last one was the 7:17 PM front-door alert." }, { text: "ok" }],
          text: question,
        )

        expect(nudged?(client)).to be(false)
      end
    end
  end

  # A refusal is exempted from the false-claim guard on purpose (DENIAL_RX:
  # declining honestly is the right answer when nothing ran), which is why this
  # needed its own arm rather than a tweak to that one.
  it "catches the refusal shape" do
    client = run(
      [
        { text: "Hm, I can't show the person itself from here." },
        { tool_calls: [{ name: :call_jil_function, arguments: { "name" => "Camera Last Seen" } }] },
        { text: "Someone came by at 3:30 this afternoon." },
      ],
      text: "Show me the last person that rang the doorbell",
    )

    expect(nudged?(client)).to be(true)
    expect(reply.body).to eq("Someone came by at 3:30 this afternoon.")
  end

  it "names the function it wants called" do
    client = run(
      [{ text: "I can't pull up a camera." }, { text: "ok" }],
      text: "Who was at the door?",
    )

    expect(nudge_sent(client)).to include("`Camera Last Seen`")
    expect(nudge_sent(client)).to include("expect_result")
  end

  describe "what it must leave alone" do
    # The live view has always worked. Nudging it would spend a round telling it
    # to do the thing it just did.
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

    # Prod 3743, "Let me know the next time somebody comes to the door" — same
    # nouns, but it's a watch, and it got the doorbell listener correctly. The
    # proposal normally keeps this arm out of reach; this is the turn where the
    # watch itself failed to resolve and the nudge must not send it to a camera.
    it "leaves a forward-looking watch request alone" do
      client = run(
        [{ text: "Kk! You'll get a ping when the doorbell rings." }, { text: "ok" }],
        text: "Let me know the next time somebody comes to the door",
      )

      expect(nudged?(client)).to be(false)
    end

    it "leaves a plain doorbell mention alone" do
      client = run(
        [{ text: "Sure, adding that." }, { text: "ok" }],
        text: "Add doorbell batteries to the shopping list",
      )

      expect(nudged?(client)).to be(false)
    end

    # The doorbell notification turns (prod 3749, 3753) carry the word in their
    # own seed text and answer with no tool call by design.
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

    # An empty index means no camera is wired here, and the refusal was the
    # honest answer. Pointing at a function that isn't in the list would be
    # telling it to invent a name.
    it "stays quiet when this person has no camera function" do
      last_seen.destroy!

      client = run(
        [{ text: "Hm, I can't pull up a camera from here." }, { text: "ok" }],
        text: "Show me the last person that rang the doorbell",
      )

      expect(nudged?(client)).to be(false)
    end

    # Same reason: opting a task out of Buddy is a decision about whether it may
    # be called at all.
    it "stays quiet when the camera function isn't buddy-enabled" do
      last_seen.update!(buddy_enabled: false)

      client = run(
        [{ text: "Hm, I can't pull up a camera from here." }, { text: "ok" }],
        text: "Show me the last person that rang the doorbell",
      )

      expect(nudged?(client)).to be(false)
    end
  end
end
