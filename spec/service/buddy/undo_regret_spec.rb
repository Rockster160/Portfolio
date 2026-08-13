require "rails_helper"

# The mirror of a disputed action. There, the person says something DIDN'T
# happen; here they say something that DID happen shouldn't have.
#
# Prod 3483-3486. Suki learned two Afrikaans terms off Eve's example — both
# define_term buttons executed — and seven minutes later an undo row came back
# "Undone - unlearn lekker". Seventeen seconds after that:
#
#   3485 "No, I didn't mean to undo that!"
#   3486 "No worries at all!! Nothing got undone on my side, so you're still good!"
#
# `lekker` was gone from household_glossary_terms and stayed gone. Nothing in
# DISPUTED_ACTION_RX covers this shape, because nothing about it reads as a
# dispute — she was correcting herself, not Buddy — so the reply was written
# from memory, and memory said the term had been learned.
RSpec.describe "Buddy undo-regret turns" do
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

  def nudges(client)
    client.calls.filter_map { |c| c.input.last[:content] if c.input.last[:role] == :developer }
  end

  describe "recognizing it" do
    def regrets?(text) = Buddy::GPT::Turn::UNDO_REGRET_RX.match?(text)

    it "catches the one that got past it" do
      expect(regrets?("No, I didn't mean to undo that!")).to be(true)
    end

    it "catches the other ways of saying it" do
      expect(regrets?("I didn’t mean to remove it")).to be(true)
      expect(regrets?("why did you delete that")).to be(true)
      expect(regrets?("can you put it back")).to be(true)
      expect(regrets?("I still want that one")).to be(true)
      expect(regrets?("undo the undo please")).to be(true)
    end

    # A false fire costs one corrective round, so this is about staying out of
    # ordinary conversation rather than about precision.
    it "leaves alone messages that regret nothing" do
      expect(regrets?("go ahead and undo that")).to be(false)
      expect(regrets?("I didn't mean to say that")).to be(false)
      expect(regrets?("remove the second one please")).to be(false)
      expect(regrets?("did you undo it?")).to be(false)
    end

    # The other half of the pair still has its own arm; neither is a subset of
    # the other and both have to keep firing on their own shapes.
    it "doesn't take over from the disputed-action check" do
      expect(Buddy::GPT::Turn::DISPUTED_ACTION_RX.match?("No, I didn't mean to undo that!")).to be(false)
      expect(regrets?("you never sent it")).to be(false)
    end
  end

  describe "a reply written without looking" do
    let(:regret) { "No, I didn't mean to undo that!" }

    it "gets a corrective round telling it to read recent_actions" do
      client = run(
        [
          { text: "No worries at all!! Nothing got undone on my side, so you're still good!" },
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["recent_actions"] } }] },
          { text: "You're right, lekker came off — putting it back now." },
        ],
        text: regret,
      )

      expect(nudges(client)).to eq([Buddy::GPT::Turn::UNDO_REGRET_NUDGE])
    end

    it "spends only the one round on it" do
      client = run(
        [
          { text: "Nothing got undone!" },
          { text: "Nothing got undone!" },
          { text: "Nothing got undone!" },
        ],
        text: regret,
      )

      expect(nudges(client).count(Buddy::GPT::Turn::UNDO_REGRET_NUDGE)).to eq(1)
    end

    # The whole point of the nudge is that putting it back is a call, not a
    # sentence — so a turn that goes and does it is left alone.
    it "is left alone once it has looked" do
      client = run(
        [
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["recent_actions"] } }] },
          { text: "Yep, that one came off — back on now." },
        ],
        text: regret,
      )

      expect(nudges(client)).to be_empty
    end
  end

  # Nobody spoke, so there's nothing to regret.
  it "never fires on a self-initiated turn" do
    seed = convo.byte_messages.create!(
      user: user, direction: :outbound, state: :pending,
      body: "Say something about the day", metadata: { "kind" => "buddy_trigger", "hidden" => true }
    )
    client = FakeBuddyClient.new([{ text: "Nothing got undone, put it back on the list." }])
    Buddy::GPT::Turn.run!(seed, client: client)

    expect(nudges(client)).to be_empty
  end
end
