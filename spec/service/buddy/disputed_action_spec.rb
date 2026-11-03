require "rails_helper"

# When someone disputes that an action happened, only `recent_actions` can
# settle it, so a reply written without reading it gets one corrective round.
RSpec.describe "Buddy disputed-action turns" do
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    convo.update_columns(buddy_theme: "byte", buddy_expression: "happy")
  end

  def user_says(text)
    convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: text)
  end

  def run(rounds, text:)
    client = FakeBuddyClient.new(rounds)
    Buddy::GPT::Turn.run!(user_says(text), client: client)
    client
  end

  def reply
    convo.byte_messages.where(direction: :inbound).order(:created_at).last
  end

  def nudges(client)
    client.calls.filter_map { |c| c.input.last[:content] if c.input.last[:role] == :developer }
  end

  describe "recognizing the dispute" do
    def disputes?(text)
      Buddy::GPT::Turn::DISPUTED_ACTION_RX.match?(text)
    end

    it "catches denials, corrections (determiner or not) and accusations" do
      [
        "Oh you didn’t do anything",
        "That's not correct. That's the laundry button being pressed.",
        "You just copied what you said before without actually running the task.",
        "I don't think you actually moved it to home. I think that's a lie.",
        "That's not the correct company.",
        "that's not the right one",
        "That's not a correct reading of it",
        "that's not my right address",
        "you never sent it",
        "did you actually do that?",
        "nothing happened",
        "you're lying",
      ].each { |text| expect(disputes?(text)).to be(true), text }
    end

    # A false fire costs one corrective round, so this list is about staying out
    # of the way of ordinary conversation rather than about precision.
    it "leaves alone messages that dispute nothing" do
      [
        "that's not the one I meant, I wanted the other list",
        "I didn't do the dishes yet",
        "thanks, that's right",
        "can you tell me what happened?",
      ].each { |text| expect(disputes?(text)).to be(false), text }
    end
  end

  describe "a reply written without looking" do
    let(:disputed) { "I don't think you actually moved it to home. I think that's a lie." }

    it "gets a corrective round telling it to read recent_actions" do
      client = run(
        [
          { text: "Ahh, yep. You’re right - it’s already in home, so there wasn’t anything to move." },
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["recent_actions"] } }] },
          { text: "I did move it - it went from Work to Home at 6:03 PM." },
        ],
        text: disputed,
      )

      expect(nudges(client)).to eq([Buddy::GPT::Turn::CHECK_ACTIONS_NUDGE])
      expect(reply.body).to eq("I did move it - it went from Work to Home at 6:03 PM.")
    end

    # The nudge fires ahead of the arms that read the REPLY, because a confident
    # "I did" and a meek "you're right" are the same failure when neither looked.
    it "fires on an argument as readily as on a capitulation" do
      client = run(
        [
          { text: "Ahh, nope, I did." },
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["recent_actions"] } }] },
          { text: "You’re right, that didn’t go through. Doing it now." },
        ],
        text: "Oh you didn’t do anything",
      )

      expect(nudges(client)).to eq([Buddy::GPT::Turn::CHECK_ACTIONS_NUDGE])
    end

    it "spends only the one round on it" do
      client = run(
        [
          { text: "Ahh, yep. You’re right." },
          { text: "Ahh, yep. You’re right." },
          { text: "Ahh, yep. You’re right." },
        ],
        text: disputed,
      )

      expect(nudges(client).count(Buddy::GPT::Turn::CHECK_ACTIONS_NUDGE)).to eq(1)
    end
  end

  describe "a reply that already looked" do
    it "is left alone" do
      client = run(
        [
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["recent_actions"] } }] },
          { text: "It’s not on the list, so it didn’t happen. Doing it now." },
        ],
        text: "I don't think you actually moved it to home.",
      )

      expect(nudges(client)).to be_empty
    end

    # `sections: null` is get_context's "everything", which includes it.
    it "counts a whole-context fetch as having looked" do
      client = run(
        [
          { tool_calls: [{ name: :get_context, arguments: { "sections" => nil } }] },
          { text: "It’s not on the list, so it didn’t happen." },
        ],
        text: "you didn't do it",
      )

      expect(nudges(client)).to be_empty
    end

    it "does not count a fetch of some other section" do
      client = run(
        [
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
          { text: "Ahh, yep. You’re right." },
          { text: "Ahh, yep. You’re right." },
        ],
        text: "you didn't do it",
      )

      expect(nudges(client)).to eq([Buddy::GPT::Turn::CHECK_ACTIONS_NUDGE])
    end
  end

  # The nudge asks for a completion sentence about an EARLIER turn, and the
  # retraction guard reads every completion sentence as a claim about THIS one.
  # Without the carve-out the fix would answer a disputed action correctly and
  # then erase the answer.
  describe "reporting back what the record says" do
    it "keeps a true past-tense answer that nothing this turn backs up" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: false)

      run(
        [
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["recent_actions"] } }] },
          { text: "Yep - I logged it at 6:03 PM, it’s on the list." },
        ],
        text: "I don't think you actually logged that.",
      )

      expect(reply.body).to eq("Yep - I logged it at 6:03 PM, it’s on the list.")
      expect(reply.metadata["retracted_claim"]).to be_nil
    end

    it "still retracts a completion claim on a turn that never looked" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: false)

      run([{ text: "Done, logged it." }, { text: "Done, logged it." }], text: "log a coffee")

      expect(reply.metadata["retracted_claim"]).to be(true)
    end
  end

  # A watch firing writes its own notification; there is no person on the other
  # side of it to be disputing anything.
  describe "a self-initiated turn" do
    it "never nudges, whatever the seed says" do
      seed = convo.byte_messages.create!(
        user:      user,
        direction: :outbound,
        state:     :sent,
        body:      "you didn't do anything",
        metadata:  { "kind" => "buddy_trigger", "hidden" => "true" },
      )
      client = FakeBuddyClient.new([{ text: "Deploy finished." }])
      Buddy::GPT::Turn.run!(seed, client: client)

      expect(nudges(client)).to be_empty
    end
  end
end
