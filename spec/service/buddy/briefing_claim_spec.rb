require "rails_helper"

# A briefing that announces itself instead of being itself.
#
# "Hiii! Your Today is ready ✨" is not a briefing, it's a receipt for one that
# was never written — and nothing else is coming. Two routes in: the
# `today_briefing` tool used to be callable from the briefing turn, and once one
# reply lands like this it sits in history teaching every briefing after it.
# Dev, 19 Aug: 28 of them in a row, then the next hand-run copied the shape.
RSpec.describe "Buddy briefing self-announcement" do
  let(:user)   { create(:user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(Buddy::Errors).to receive(:report)
    convo.update_columns(buddy_theme: "byte")
  }

  # Runs a real briefing turn whose model reply is `text`, and returns what the
  # person actually ends up seeing.
  def briefing_reply(text)
    seed = convo.byte_messages.create!(
      user: user, direction: :outbound, state: :sent,
      body: Buddy::TodayBriefing.seed(user),
      metadata: { "kind" => "buddy_trigger", "hidden" => true, "buddy_action" => "today" },
    )
    Buddy::GPT::Turn.run!(seed, client: FakeBuddyClient.new([{ text: text }]))
    convo.byte_messages.where(direction: :inbound).order(:id).last.body
  end

  def ordinary_reply(text)
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "hey")
    Buddy::GPT::Turn.run!(inbound, client: FakeBuddyClient.new([{ text: text }]))
    convo.byte_messages.where(direction: :inbound).order(:id).last.body
  end

  describe "the claim is cut and the real briefing kept" do
    it "drops a leading announcement and leaves what followed" do
      body = briefing_reply("Your Today briefing is ready! Dentist at 2, and the bins go out tonight.")

      expect(body).to include("Dentist at 2")
      expect(body).not_to match(/briefing is ready/i)
    end

    # Verbatim shapes from the 28 that went out in dev, with a real briefing
    # behind them.
    it "catches the shapes it actually came out as" do
      [
        "Hiii! Your Today is ready ✨ Dentist at 2, bins tonight.",
        "Heyyy! Done! Your Today briefing went out 💛 Dentist at 2, bins tonight.",
        "Hi hi! All set! Your Today briefing is up ✨ Dentist at 2, bins tonight.",
        "Okay! Your Today briefing just popped in ✨ Dentist at 2, bins tonight.",
        "Heyyy! Your Today's out now, nice and tidy ✨ Dentist at 2, bins tonight.",
        "Your rundown is on its way! Dentist at 2, bins tonight.",
      ].each do |text|
        body = briefing_reply(text)

        expect(body).to include("Dentist at 2"), "lost the briefing in: #{text}"
        expect(body).not_to match(/(?:today|briefing|rundown)\s*(?:is|just)?\s*(?:ready|up|out|on its way|went out|popped in)/i),
          "left the claim in: #{body}"
      end
    end
  end

  describe "what it must not touch" do
    # The whole point is that a real briefing survives intact.
    it "leaves an ordinary briefing completely alone" do
      text = "Morning! Dentist at 2, and the bins go out tonight. Quiet otherwise."

      expect(briefing_reply(text)).to eq(text)
    end

    it "leaves a briefing that merely mentions today alone" do
      text = "Morning! Today's mostly clear. Dentist at 2 is the only thing on."

      expect(briefing_reply(text)).to eq(text)
    end

    # Outside a briefing this sentence is perfectly honest — the tool really did
    # just post one.
    it "leaves the same sentence alone on an ordinary turn" do
      text = "Your Today briefing is on its way!"

      expect(ordinary_reply(text)).to eq(text)
    end
  end

  describe "when there is nothing left" do
    # A briefing that was ONLY a claim never got written. Reporting it makes a
    # silent failure loud rather than shipping an empty message.
    it "reports rather than posting an empty briefing" do
      briefing_reply("Hiii! Your Today is ready ✨")

      expect(Buddy::Errors).to have_received(:report).with(
        hash_including(section: "turn.briefing_claim"),
      )
    end

    it "still posts something rather than nothing at all" do
      expect(briefing_reply("Hiii! Your Today is ready ✨")).to be_present
    end
  end
end
