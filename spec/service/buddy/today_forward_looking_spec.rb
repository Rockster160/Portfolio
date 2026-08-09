require "rails_helper"

# The "Today" briefing must be forward-looking: passed agenda items are flagged,
# the day's weather drops once it's late, and the plunge advisor only speaks to
# FUTURE rain.
RSpec.describe "Buddy Today forward-looking" do
  let(:user) { create(:user) }
  let(:tz)   { ActiveSupport::TimeZone["America/Denver"] }

  before { allow(user).to receive(:timezone).and_return("America/Denver") }

  # Prod 2516 opened "Hey hey, Rocco. Morning's got some real shape to it." -
  # the right words landing on a flat period, which is what the opener rule had
  # just been rewritten to prevent.
  #
  # The rule was added to the system prompt only. But the briefing seed carries
  # four paragraphs of its own opener guidance, and that is the most specific
  # instruction the model has about how to open THIS message - so a rule living
  # anywhere else loses to it. Tone guidance has to be where the model is
  # actually reading about the thing it's writing.
  describe "the greeting the briefing asks for" do
    it "tells the briefing itself to land it lifted, not only the system prompt" do
      expect(Buddy::TodayBriefing.seed(user)).to include("warm and lifted")
    end

    # The same reply closed with "Which, rude of the calendar, but at least
    # it's a plan." - a phrase that appears nowhere except inside a don't-do
    # example in this very seed. A memorable line in a counter-example is still
    # a line the model read, and it borrows it.
    it "does not hand the model a phrase to borrow inside a don't-do example" do
      expect(Buddy::TodayBriefing.seed(user)).not_to include("rude of the calendar")
    end
  end

  # Prod 2528 answered a Today tap with twelve chore names in one comma-run,
  # credited Rocco for a chore recorded for someone else, and closed on a 💙
  # that wasn't about anything. Every soft version of "don't recite" was already
  # in the seed; what wasn't was a number, and what WAS in there was an explicit
  # licence for the shape that went out.
  describe "the briefing it asks for" do
    let(:seed) { Buddy::TodayBriefing.seed(user) }

    it "caps how many chores may be named at a hard number" do
      expect(seed).to include("Name at most three of them")
      expect(seed).to include("Fewer than three is normal")
    end

    # Every version of the cap that argued with the model in prose lost: a hard
    # "THREE NAMES, TOTAL", "a daily is never one of your three", a re-sorted
    # bucket. Aug 7 named six and Aug 8 named six. The roster is withheld from
    # the turn now (ContextTool::BRIEFING_WITHHELD), so the seed stops arguing
    # about lists it can no longer reach - a rule pointing at an absent section
    # is how a model ends up explaining an absence or inventing a filler.
    it "stops arguing with sections this turn cannot see" do
      expect(seed).not_to include("chores_pending_today")
      expect(seed).not_to include("chores_done_today")
      expect(seed).not_to include("chores_hot_picks")
      expect(seed).to include("it's the whole chore section of your context")
    end

    it "says to drop chores entirely on a day with nothing due" do
      expect(seed).to include("say nothing about chores at all")
    end

    # Prod 2756 called `Monica Murton's Birthday` "the birthday", which drops
    # the only part of it that meant anything.
    it "refuses a bare category where the item has a name" do
      expect(seed).to include("NAME THE THING")
      expect(seed).to include("WHOSE birthday")
    end

    # A 2x is most of them; a 5x is the one thing on the day worth pointing at.
    it "distinguishes an unusual hot pick from a routine one" do
      expect(seed).to include("`hot` multiplier")
      expect(seed).to include("a plain 2x is ordinary")
    end

    it "no longer offers the skim-list shape it produced" do
      expect(seed).not_to include("Still pending: X, Y, Z")
      expect(seed).to include('don\'t write "Still pending:" followed by anything')
    end

    # The completions section is withheld from this turn, so the danger isn't
    # miscrediting what it can see - it's inventing a completion it can't.
    it "refuses to hand the person credit for a chore the house did" do
      expect(seed).to include("Never tell me I DID something")
      expect(seed).to include("ANYONE in the house")
    end

    it "asks for an emoji that's about something" do
      expect(seed).to include("has to be ABOUT something")
    end

    it "asks for odd clock times to be rounded" do
      expect(seed).to include("just before 8")
    end

    # The chore rules come out entirely for someone who doesn't have chores,
    # rather than pointing them at sections that aren't in their context.
    it "drops the chore guidance for someone without chores" do
      allow(Buddy::Features).to receive(:enabled?).with(user, :chores).and_return(false)

      bare = Buddy::TodayBriefing.seed(user)
      expect(bare).not_to include("THREE NAMES")
      expect(bare).not_to include("chores_pending_today")
      expect(bare).not_to match(/\n{3,}/)
    end
  end

  describe "today_agenda passed flag" do
    it "flags timed events that already started, leaves upcoming ones unflagged" do
      travel_to(tz.parse("2026-07-28 14:00")) do
        agenda = Agenda.create!(user: user, name: "Mine")
        AgendaItem.create!(
          agenda: agenda, name: "Morning standup", kind: :event,
          start_at: tz.parse("2026-07-28 09:00"), end_at: tz.parse("2026-07-28 09:30")
        )
        AgendaItem.create!(
          agenda: agenda, name: "Evening call", kind: :event,
          start_at: tz.parse("2026-07-28 18:00"), end_at: tz.parse("2026-07-28 18:30")
        )

        conversation = user.byte_conversations.create!(mode: :buddy)
        today = Buddy::Context.build(user, conversation)[:today_agenda]
        passed = today.find { |i| i[:title] == "Morning standup" }
        ahead  = today.find { |i| i[:title] == "Evening call" }

        expect(passed[:passed]).to be(true)
        expect(ahead[:passed]).to be_nil
      end
    end
  end

  describe "weather_block time gating" do
    before do
      allow(WeatherService).to receive_messages(summary: "currently 72°F, clear. today high 88°F.", week_outlook: "rain Thu")
    end

    it "includes today's weather in the morning" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        expect(Buddy::TodayBriefing.weather_block(user)).to include("Today:").and include("Comfort read")
      end
    end

    it "carries the comfort bands so the briefing frames the number rather than reciting it" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        block = Buddy::TodayBriefing.weather_block(user)
        expect(block).to include("currently 72°F, clear")
        expect(block).to include("comfortable sweet spot")
        expect(block).to match(/hot/)
      end
    end

    it "drops today's weather in the evening, keeps the week outlook" do
      travel_to(tz.parse("2026-07-28 21:00")) do
        block = Buddy::TodayBriefing.weather_block(user)
        expect(block).not_to include("Today:")
        expect(block).not_to include("Comfort read")
        expect(block).to include("This week to flag")
      end
    end

    # Off-prod, or with no API key, there's simply no forecast. Inject nothing
    # rather than a heading with nothing under it.
    it "is empty when there's no weather to be had" do
      allow(WeatherService).to receive_messages(summary: nil, week_outlook: nil)

      travel_to(tz.parse("2026-07-28 08:00")) do
        expect(Buddy::TodayBriefing.weather_block(user)).to eq("")
      end
    end
  end

  describe "plunge advisor ignores rain that already fell" do
    it "stays silent when the only rain was earlier in the day" do
      payload = {
        "hourly" => (0..23).map { |h|
          local = tz.parse("2026-07-28 #{format("%02d", h)}:00")
          e = { "dt" => local.to_i, "clouds" => 5, "weather" => [{ "main" => "Clear" }] }
          if [9, 10].include?(h) # rain in the MORNING only
            e["weather"] = [{ "main" => "Rain" }]
            e["rain"] = { "1h" => 1.0 }
          end
          e
        },
        "daily"  => [{
          "dt"      => tz.parse("2026-07-28 12:00").to_i,
          "sunrise" => tz.parse("2026-07-28 06:00").to_i,
          "sunset"  => tz.parse("2026-07-28 20:00").to_i,
        }],
      }
      allow(WeatherService).to receive(:data).and_return(payload)

      # It's 3pm — the 9-10am rain is done, nothing ahead → nothing to say.
      expect(Buddy::PlungeAdvisor.briefing_block(user, now: tz.parse("2026-07-28 15:00"))).to eq("")
    end
  end
end
