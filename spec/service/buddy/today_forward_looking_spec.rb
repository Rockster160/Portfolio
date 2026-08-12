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

  # A Today always opens with a hello. It's part of the shape of the thing, not
  # a reaction to how long it's been - so there is no branch here, and the
  # thread's history is not an input.
  #
  # The seed used to work it out from the timestamps and say DON'T GREET when
  # they'd spoken inside 30 minutes. That was a better-informed branch than the
  # model's own judgement and still the wrong question: asking for a second
  # Today an hour after the first is not a reason to be greeted like the
  # conversation never paused.
  describe "whether to greet at all" do
    let(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte") }

    def person_said(text, at:)
      conversation.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: text, created_at: at,
      )
    end

    it "orders a greeting when the briefing arrives out of the blue" do
      person_said("night", at: 9.hours.ago)

      expect(Buddy::TodayBriefing.seed(user)).to include("OPEN WITH A GREETING").and include("warm and lifted")
    end

    it "orders one on a thread that has never been spoken in" do
      expect(Buddy::TodayBriefing.seed(user)).to include("OPEN WITH A GREETING")
    end

    it "orders one when they were talking a moment ago" do
      person_said("what's up", at: 2.minutes.ago)

      expect(Buddy::TodayBriefing.seed(user)).to include("OPEN WITH A GREETING")
    end

    # Two in a row is fine, and saying so is the point - left unsaid, "we just
    # did this" is exactly the reasoning that skips it.
    it "says out loud that back to back is fine" do
      seed = Buddy::TodayBriefing.seed(user)

      expect(seed).to include("second in a row")
      expect(seed).not_to include("DON'T GREET")
    end

    it "leaves the model no branch to take either way" do
      seed = Buddy::TodayBriefing.seed(user)

      expect(seed).not_to include("when it fits")
      expect(seed).not_to include("Skip it when")
    end

    # deliver! is the scheduled path, and it's the one the misses came from.
    it "carries the order through the scheduled delivery" do
      person_said("still up", at: 3.minutes.ago)
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)

      msg = Buddy::TodayBriefing.deliver!(user, conversation)

      expect(msg.body).to include("OPEN WITH A GREETING")
    end
  end

  # Prod 2528 answered a Today tap with twelve chore names in one comma-run,
  # credited Rocco for a chore recorded for someone else, and closed on a 💙
  # that wasn't about anything. Every soft version of "don't recite" was already
  # in the seed; what wasn't was a number, and what WAS in there was an explicit
  # licence for the shape that went out.
  describe "the briefing it asks for" do
    let(:seed) { Buddy::TodayBriefing.seed(user) }

    # THE rule for this file, and the reason most of what used to be asserted
    # here is gone. Every concrete example ever written into this prompt came
    # back out of it: two agenda items were named here purely as what-NOT-to-say
    # illustrations, and both were then read out by name on the days they came
    # round. Naming a thing in order to forbid it still puts the name in front
    # of the model. So the seed carries no record names, and no quoted sample
    # sentences for it to borrow either.
    it "hands the model no concrete example it can echo" do
      backticked = seed.scan(/`([A-Z][A-Za-z0-9' .-]{3,40})`/).flatten.uniq

      # `Part of day` is a context field label, not a record.
      expect(backticked - ["Part of day"]).to be_empty
      # Sample phrasing in quotes is the same trap in a different costume.
      # Bounded to a single line so the match can't run between two unrelated
      # short quotes and report the prose in between.
      expect(seed.scan(/"[^"\n]{25,}"/)).to be_empty
    end

    it "tells it the filtering is already done rather than how to do it" do
      expect(seed).to include("the filtering is done and none of it is yours to redo")
      expect(seed).to include("Naming none of them is a perfectly good briefing")
    end

    # The routine sections are withheld from this turn outright
    # (ContextTool::BRIEFING_WITHHELD), so the seed must not reference them: a
    # rule about an absent section makes the model explain an absence or invent
    # a filler to fill it.
    it "never mentions a section this turn cannot see" do
      Buddy::GPT::ContextTool::BRIEFING_WITHHELD.each do |section|
        expect(seed).not_to include(section.to_s)
      end
    end

    it "points at the notable views instead" do
      expect(seed).to include("`today_notable`")
      expect(seed).to include("`upcoming_notable`")
    end

    it "says an empty day is a correct briefing, not one to pad out" do
      expect(seed).to include("That is a correct briefing, not a failed one")
    end

    # A brief mention still has to be specific: compressing an item to its
    # category strips the only part that couldn't have been guessed.
    it "refuses a bare category where the item has a name" do
      expect(seed).to include("NAME THE THING")
      expect(seed).to include("Being brief means mentioning FEWER things")
    end

    it "treats a hot multiplier as already-rare rather than something to weigh" do
      expect(seed).to include("`hot` multiplier")
      expect(seed).to include("Only the exceptional ones reach you")
    end

    it "refuses to hand the person credit for a chore the house did" do
      expect(seed).to include("Never tell me I DID something")
      expect(seed).to include("crediting me for one is a guess")
    end

    it "asks for an emoji that's about something" do
      expect(seed).to include("has to be ABOUT something")
    end

    it "asks for odd clock times to be rounded" do
      expect(seed).to include("Round odd clock times")
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
