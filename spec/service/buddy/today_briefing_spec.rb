require "rails_helper"

RSpec.describe "Buddy Today briefing" do
  # A briefing that announces itself ("Your Today is ready ✨") instead of
  # being itself has the claim cut, keeping whatever real briefing followed.
  describe "announcing itself" do
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

    it "cuts a leading announcement and keeps what followed", :aggregate_failures do
      [
        "Your Today briefing is ready! Dentist at 2, and the bins go out tonight.",
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

    it "leaves a real briefing, even one mentioning today, completely alone", :aggregate_failures do
      [
        "Morning! Dentist at 2, and the bins go out tonight. Quiet otherwise.",
        "Morning! Today's mostly clear. Dentist at 2 is the only thing on.",
      ].each { |text| expect(briefing_reply(text)).to eq(text) }
    end

    # Outside a briefing this sentence is honest — the tool really did post one.
    it "leaves the same sentence alone on an ordinary turn" do
      text = "Your Today briefing is on its way!"

      expect(ordinary_reply(text)).to eq(text)
    end

    describe "when there is nothing left" do
      # A briefing that was ONLY a claim never got written.
      it "reports it, and still posts something rather than nothing", :aggregate_failures do
        expect(briefing_reply("Hiii! Your Today is ready ✨")).to be_present
        expect(Buddy::Errors).to have_received(:report).with(
          hash_including(section: "turn.briefing_claim"),
        )
      end
    end
  end

  # With a forecast table in the facts, the seed points at the table and drops
  # the weather order the repair keys off.
  describe "a seed whose forecast goes on as a table" do
    let(:facts) {
      {
        name:     "Rocco",
        today:    [],
        due:      [],
        jobs:     [],
        week:     [],
        stash:    [],
        waiting:  [],
        weather:  { high: 65, low: 41, notable: "rain", week: "rain Wed" },
        alpine:   { today: ["Rain in Alpine 1-3pm"], week: [] },
        forecast: [{ date: Date.current, high: 65, low: 41 }],
      }
    }
    let(:seed) { Buddy::TodayBriefing.seed(nil, nil, facts: facts) }

    it "tells the companion the table is there instead of asking for the figures" do
      expect(seed).to include(Buddy::TodayBriefing::WRITING_RULES[:forecast])
      expect(seed).not_to include(Buddy::TodayBriefing::WEATHER_DIRECTIVE, Buddy::TodayBriefing::WRITING_RULES[:alpine])
    end
  end

  describe ".stash_age_said?" do
    def said?(body, waiting: "7 weeks")
      Buddy::TodayBriefing.stash_age_said?(body, { idea: "Kennel auto-open idea", waiting: waiting })
    end

    it "takes the age as written, spelled out, or as a wordy label", :aggregate_failures do
      [
        ["that kennel auto-open idea, sitting there from 7 weeks ago", "7 weeks"],
        ["it has been sitting there for 7 weeks now", "7 weeks"],
        ["seven weeks is a long time to carry that one!", "7 weeks"],
        ["three weeks on and it is still there", "3 weeks"],
        ["you stashed that today", "today"],
        ["that one has been there since yesterday", "since yesterday"],
        ["anything at all", nil],
      ].each { |body, waiting| expect(said?(body, waiting: waiting)).to be(true), body }
    end

    it "does not take a paraphrase or a different figure as the age", :aggregate_failures do
      [
        ["still sitting there from a while back", "7 weeks"],
        ["Fridge leftovers are still on your mind", "3 weeks"],
        ["that idea from 2 weeks ago", "7 weeks"],
        ["7 days of that", "7 weeks"],
        ["that one is still hanging around", "since yesterday"],
      ].each { |body, waiting| expect(said?(body, waiting: waiting)).to be(false), body }
    end
  end

  describe ".without_calm_week" do
    let(:days) { %w[Sun Mon] }

    it "cuts a calm-week clause or sentence and keeps everything else", :aggregate_failures do
      [
        [
          "It's 67 right now, with a high of 87 and a low of 66 today, and the week looks pretty clear overall, so nothing spicy lurking out there. If you want, I can help pick the next thing.",
          "It's 67 right now, with a high of 87 and a low of 66 today. If you want, I can help pick the next thing.",
        ],
        [
          "Good morning!!\n\nThe week ahead looks mostly steady from here, so nothing is shouting for attention just yet! Have a good one.",
          "Good morning!!\n\nHave a good one.",
        ],
      ].each { |body, out| expect(Buddy::TodayBriefing.without_calm_week(body, days)).to eq(out) }
    end

    # A flagged day by name is the model doing the job, however flatly it reads.
    it "leaves a flagged day, a calm claim not about the week, a busy week, and a cut that leaves nothing", :aggregate_failures do
      [
        "Rain Sunday and Monday, so the week is not exactly clear.",
        "Your morning looks clear, with nothing before 11.",
        "The week ahead is packed, and I love that for you.",
        "The week looks clear.",
      ].each { |body| expect(Buddy::TodayBriefing.without_calm_week(body, days)).to eq(body) }
    end
  end

  describe "recursion" do
    let(:user)   { create(:user) }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    around { |ex| Sidekiq::Testing.fake! { ex.run } }

    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      convo.update_columns(buddy_theme: "byte")
    }

    # Tool names come back as symbols.
    def names_in(client)
      client.calls.first.tools.filter_map { |schema| (schema[:name] || schema["name"])&.to_sym }
    end

    # The seed the real briefing sends, marker and all.
    def seed!
      convo.byte_messages.create!(
        user:      user,
        direction: :outbound,
        state:     :sent,
        body:      Buddy::TodayBriefing.seed(user),
        metadata:  {
          "kind"         => "buddy_trigger",
          "hidden"       => true,
          "source"       => "today_scheduled",
          "buddy_action" => "today",
        },
      )
    end

    def run_briefing!(seed = seed!)
      client = FakeBuddyClient.new([{ text: "Morning! Two things today." }])
      Buddy::GPT::Turn.run!(seed, client: client)
      client
    end

    # The whole day arrives in the seed, so the briefing turn has nothing to
    # look up, and offering today_briefing let it post another seed.
    it "offers the briefing turn no tools and produces no further seed", :aggregate_failures do
      seed = seed!
      client = nil

      expect { client = run_briefing!(seed) }
        .not_to change { convo.byte_messages.where("metadata->>'buddy_action' = 'today'").count }
      expect(names_in(client)).to be_empty
    end

    it "leaves an ordinary turn its whole registry, today_briefing included" do
      inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "send me my Today")
      client  = FakeBuddyClient.new([{ text: "Sure." }])
      Buddy::GPT::Turn.run!(inbound, client: client)

      expect(names_in(client)).to include(:complete_chore, :log_event, :get_context)
      # Reachable is enough: listed by name, to be opened (see Buddy::ToolIndex).
      expect(client.calls.first.tools.pluck(:name).map(&:to_s)).to include("today_briefing")
    end
  end
end
