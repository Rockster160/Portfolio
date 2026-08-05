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
