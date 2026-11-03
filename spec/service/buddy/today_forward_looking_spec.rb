require "rails_helper"

# The "Today" briefing must be forward-looking: passed agenda items are flagged,
# the day's weather drops once it's late, and the plunge advisor only speaks to
# FUTURE rain.
RSpec.describe "Buddy Today forward-looking" do
  let(:user) { create(:user) }
  let(:tz)   { ActiveSupport::TimeZone["America/Denver"] }

  before { allow(user).to receive(:timezone).and_return("America/Denver") }

  # One of everything, in the shape Buddy::GPT::ContextTool hands over after the
  # briefing filters have run. Every subject block in the seed is gated on the
  # day actually holding something for it.
  def full_day_facts
    {
      name:    "Rocco",
      today:   [
        { time: "11:40 AM", title: "Eye Follow Up", where: "Draper", leave_by: "11:08 AM", drive_min: 22 },
        { time: "today", title: "A birthday", all_day: true },
        { time: "4:00 PM", title: "Her thing", mine: false, owner: "Chelsea" },
        { time: "9:00 AM", title: "A standup", cancelled: true },
      ],
      due:     [{ fire_at: "Fri 3:00 PM", body: "Do the dishes." }],
      jobs:    [
        { id: 1, name: "Gather trash", group: "trash" },
        { id: 2, name: "Take out trash bags", group: "trash" },
        { id: 3, name: "Replace the air filter", hot: "5x" },
      ],
      week:    [{ day: "tomorrow", time: "6:00 PM", title: "Drinks out" }],
      stash:   [{ id: 9, body: "Look at that dock again" }],
      weather: { high: 86, low: 65, notable: "windy", week: "rain Mon" },
      alpine:  { today: ["Rain in the forecast"], week: ["tomorrow 1pm-2pm"] },
    }
  end

  def empty_facts(**overrides)
    { name: "Rocco", today: [], due: [], jobs: [], week: [], stash: [], weather: {}, alpine: {} }.merge(overrides)
  end

  def a_full_day!
    allow(Buddy::Features).to receive(:enabled?).and_call_original
    allow(Buddy::Features).to receive(:enabled?).with(user, :chores).and_return(true)
    allow(Buddy::BriefingFacts).to receive(:build).and_return(full_day_facts)
  end

  describe "the plunge window" do
    def seed_for(alpine)
      allow(Buddy::BriefingFacts).to receive(:build).and_return(empty_facts(alpine: alpine))
      Buddy::TodayBriefing.seed(user)
    end

    it "reaches the seed only when the advisor offered one", :aggregate_failures do
      offered = seed_for(today: ["Rain in Alpine 1-4pm", "Good plunge window: clear from 4pm"], week: [])
      wet = seed_for(today: ["Rain in Alpine 1-4pm"], week: [])

      expect(offered).to include("Good plunge window: clear from 4pm")
      expect(wet).to include("Rain in Alpine 1-4pm")
      expect(wet).not_to include("plunge")
    end
  end

  # A Today always orders a greeting, whatever the thread's history - and
  # Buddy::GPT::Turn keys its hello repair off that order.
  describe "whether to greet at all" do
    let(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte") }

    def person_said(text, at:)
      conversation.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: text, created_at: at,
      )
    end

    it "orders a greeting on a fresh thread, after a long gap, and moments after talking", :aggregate_failures do
      expect(Buddy::TodayBriefing.greeting_ordered?(Buddy::TodayBriefing.seed(user))).to be(true)

      person_said("night", at: 9.hours.ago)
      expect(Buddy::TodayBriefing.greeting_ordered?(Buddy::TodayBriefing.seed(user))).to be(true)

      person_said("what's up", at: 2.minutes.ago)
      expect(Buddy::TodayBriefing.greeting_ordered?(Buddy::TodayBriefing.seed(user))).to be(true)
    end

    it "carries the order through the scheduled delivery" do
      person_said("still up", at: 3.minutes.ago)
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)

      msg = Buddy::TodayBriefing.deliver!(user, conversation)

      expect(Buddy::TodayBriefing.greeting_ordered?(msg.body)).to be(true)
    end
  end

  describe "the day, handed over as rows" do
    it "puts each kind of thing in its section, shaped as one line each", :aggregate_failures do
      a_full_day!
      seed = Buddy::TodayBriefing.seed(user)

      expect(seed).to include("ON TODAY")
      expect(seed).to include("- 11:40 AM · Eye Follow Up · Draper · leave by 11:08 AM (22 min drive)")
      expect(seed).not_to match(/^Eye Follow Up: leave by/)
      # A reminder carries no weekday: the section is today.
      expect(seed).to include("ALSO DUE TODAY")
      expect(seed).to include("- 3:00 PM · Do the dishes.")
      expect(seed).to include("JOBS TODAY")
      expect(seed).to include("- trash: Gather trash, Take out trash bags")
      expect(seed).to include("- Replace the air filter · 5x")
      expect(seed).to include("COMING UP")
      expect(seed).to include("- tomorrow · 6:00 PM · Drinks out")
      # The owner leads the title so a partner's item reads as theirs.
      expect(seed).to include("- 4:00 PM · Chelsea's Her thing")
      expect(seed).to include("cancelled")
      expect(seed).to include("all day")
      # A quoted sample line in the instructions comes back as the briefing.
      instructions = seed.split("HOW TO SAY IT").last
      expect(instructions.scan(/"[^"\n]{25,}"/)).to be_empty
      expect(instructions.scan(/`([A-Z][A-Za-z0-9' .-]{3,40})`/).flatten - ["Part of day"]).to be_empty
    end

    it "prints no empty sections on a quiet day and is much shorter for it", :aggregate_failures do
      allow(Buddy::BriefingFacts).to receive(:build).and_return(empty_facts)
      quiet = Buddy::TodayBriefing.seed(user)

      %w[ON\ TODAY ALSO\ DUE\ TODAY JOBS\ TODAY COMING\ UP].each { |heading|
        expect(quiet).not_to include(heading)
      }
      expect(Buddy::TodayBriefing.greeting_ordered?(quiet)).to be(true)

      a_full_day!
      expect(quiet.length).to be < (Buddy::TodayBriefing.seed(user).length * 0.8)
    end

    it "drops the whole jobs section for someone without chores", :aggregate_failures do
      allow(Buddy::Features).to receive(:enabled?).and_call_original
      allow(Buddy::Features).to receive(:enabled?).with(user, :chores).and_return(false)
      allow(Buddy::BriefingFacts).to receive(:build).and_return(empty_facts)

      bare = Buddy::TodayBriefing.seed(user)

      expect(bare).not_to include("JOBS TODAY")
      expect(bare).not_to match(/\n{3,}/)
    end
  end

  # `BriefingFacts` reads through ContextTool on purpose, so what the seed says
  # the day holds and what the filters would answer are the same answer.
  describe "reading the real day" do
    let!(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte") }
    let!(:household)    { ChoreHousehold.create!(name: "Home", owner_user: user) }

    around { |ex| travel_to(tz.parse("2026-09-02 08:00")) { ex.run } }

    before {
      user.update!(chore_household_id: household.id)
      agenda = Agenda.create!(user: user, name: "Mine")
      agenda.agenda_items.create!(
        name:     "Eye Follow Up",
        kind:     :event,
        start_at: tz.parse("2026-09-02 11:40"),
        end_at:   tz.parse("2026-09-02 12:20"),
      )
      ["Gather trash", "Take out trash bags"].each { |name|
        create(
          :chore, name: name, created_by_user: user, chore_household: household,
          recurrence: { freq: "weekly", by_day: ["wed"] }
        )
      }
    }

    it "names what is on the day, from the same rows the briefing filters hand over", :aggregate_failures do
      seed = Buddy::TodayBriefing.seed(user, conversation)
      facts  = Buddy::BriefingFacts.build(user, conversation)
      served = Buddy::GPT::ContextTool.new(user, conversation, briefing: true).filtered([:chores_due_today])

      expect(seed).to include("Eye Follow Up")
      expect(seed).to include("trash: Gather trash, Take out trash bags")
      expect(facts[:jobs].pluck(:name)).to eq(served[:chores_due_today].pluck(:name))
    end

    # The pre-send repairs read the facts back off the message.
    it "rides on the message, for the repairs to read back" do
      allow(BuddyDeliverWorker).to receive(:perform_async)
      allow(MonitorChannel).to receive(:broadcast_to)

      msg = Buddy::TodayBriefing.deliver!(user, conversation, scheduled: false)

      expect(msg.metadata["briefing"]["jobs"].pluck("name")).to include("Gather trash")
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

  # `BriefingFacts` keeps only what's still ahead, so a thing that already
  # happened is not in the seed at all.
  describe "things that are already done" do
    let(:conversation) { user.byte_conversations.create!(mode: :buddy) }

    it "keeps a rung reminder out of the day entirely" do
      BuddyReminder.create!(
        user: user, byte_conversation: conversation,
        body: "Finish cleaning the car.", fire_at: 20.hours.ago, fired_at: 20.hours.ago
      )

      facts = Buddy::BriefingFacts.build(user, conversation)

      expect(Buddy::TodayBriefing.seed(user, conversation)).not_to include("Finish cleaning the car")
      expect(facts[:due]).to be_empty
    end

    it "keeps a passed item out of it too" do
      allow(Buddy::GPT::ContextTool).to receive(:new).and_return(
        instance_double(
          Buddy::GPT::ContextTool,
          filtered: { today_notable: [{ time: "8:00 AM", title: "Gone already", passed: true }] },
        ),
      )

      expect(Buddy::BriefingFacts.build(user, conversation)[:today]).to be_empty
    end
  end

  describe "when to leave" do
    let(:conversation) { user.byte_conversations.create!(mode: :buddy) }

    def item_with_travel!(leave_at)
      agenda = Agenda.create!(user: user, name: "Mine")
      item   = AgendaItem.create!(
        agenda:               agenda,
        name:                 "Rose Establishment",
        kind:                 :event,
        location:             "The Rose Establishment",
        arrive_early_minutes: 5,
        start_at:             tz.parse("2026-07-28 10:00"),
        end_at:               tz.parse("2026-07-28 11:00"),
      )
      # Written past the callbacks: saving a located item kicks off the travel
      # recompute, which owns this key and would drop a hand-set one.
      item.update_columns(metadata: { "travel" => { "travel_minutes" => 32, "leave_at" => leave_at.to_i } }) # rubocop:disable Rails/SkipsModelValidations
      item
    end

    def agenda_at(clock)
      travel_to(tz.parse("2026-07-28 #{clock}")) { Buddy::Context.build(user, conversation)[:today_agenda].first }
    end

    it "hands over the leave-by while it is ahead and drops it once it has gone", :aggregate_failures do
      item_with_travel!(tz.parse("2026-07-28 09:23"))

      early = agenda_at("08:00")
      expect(early[:drive_min]).to eq(32)
      expect(early[:leave_by]).to eq("9:23am")

      expect(agenda_at("09:03")[:leave_by]).to eq("9:23am")

      # The event itself is not passed yet; only its departure is.
      late = agenda_at("10:30")
      expect(late[:title]).to eq("Rose Establishment")
      expect(late).not_to have_key(:leave_by)
      expect(Buddy::BriefingFacts.agenda_line(late)).not_to match(/leave by|drive/i)
    end

    it "leaves the key off an item with no travel at all" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        agenda = Agenda.create!(user: user, name: "Mine")
        AgendaItem.create!(
          agenda: agenda, name: "Focus", kind: :event,
          start_at: tz.parse("2026-07-28 14:00"), end_at: tz.parse("2026-07-28 15:00")
        )

        item = Buddy::Context.build(user, conversation)[:today_agenda].first

        expect(item).not_to have_key(:leave_by)
      end
    end
  end

  describe "the weather the day is handed" do
    before do
      allow(WeatherService).to receive_messages(
        today_figures: { high: 88, low: 61, rain: 10, notable: nil },
        week_outlook:  "rain Thu",
      )
    end

    def weather_at(hour)
      travel_to(tz.parse("2026-07-28 #{hour}")) { Buddy::BriefingFacts.weather(user, Time.current) }
    end

    def seed_at(hour)
      travel_to(tz.parse("2026-07-28 #{hour}")) { Buddy::TodayBriefing.seed(user) }
    end

    # Buddy::GPT::Turn decides whether to repair a missing weather line off
    # weather_ordered?, so the order must come and go with the figures.
    it "carries the figures and the order in the morning", :aggregate_failures do
      seed = seed_at("08:00")

      expect(weather_at("08:00")).to include(high: 88, low: 61)
      expect(seed).to include("High 88°F, low 61°F")
      expect(Buddy::TodayBriefing.weather_ordered?(seed)).to be(true)
      expect(seed).not_to include("- windy")
    end

    it "drops the figures and the order in the evening and keeps the week", :aggregate_failures do
      seed = seed_at("21:00")

      expect(weather_at("21:00")).to eq(week: "rain Thu")
      expect(Buddy::TodayBriefing.weather_ordered?(seed)).to be(false)
      expect(seed).to include("This week: rain Thu")
    end

    it "carries the notable thing the figures have no room for" do
      allow(WeatherService).to receive(:today_figures).and_return(high: 88, low: 61, rain: 10, notable: "windy")

      expect(seed_at("08:00")).to include("- windy")
    end

    it "is empty when there's no weather to be had", :aggregate_failures do
      allow(WeatherService).to receive_messages(today_figures: nil, week_outlook: nil)

      expect(weather_at("08:00")).to eq({})
      expect(seed_at("08:00")).not_to include("WEATHER")
    end

    it "composes the repair line off the figures", :aggregate_failures do
      [
        [{ high: 93, low: 69, rain: 0, notable: nil }, "High of 93°F today, low of 69°F."],
        [{ high: 93, low: 69, rain: 56, notable: "rain" }, "High of 93°F today, low of 69°F, with a 56% chance of rain."],
        # A label at a chance that rounds to zero keeps the label, not "0%".
        [{ high: 61, low: 44, rain: 0, notable: "rain" }, "High of 61°F today, low of 44°F, with a bit of rain around."],
        [{ high: 93, low: nil, rain: 0, notable: nil }, nil],
      ].each { |figures, line|
        expect(Buddy::TodayBriefing.weather_line(**figures)).to eq(line)
      }
    end

    describe "the week's flagged days" do
      it "spells the outlook out as a line and reads its days back", :aggregate_failures do
        outlook = "rain Mon"

        expect(Buddy::TodayBriefing.week_line("rain Thu, Fri, Sat & Sun"))
          .to eq("Rain Thursday, Friday, Saturday & Sunday this week.")
        expect(Buddy::TodayBriefing.week_line("snow Mon, windy Fri")).to eq("Snow Monday, windy Friday this week.")
        expect(Buddy::TodayBriefing.week_line(outlook)).to eq("Rain Monday this week.")
        expect(outlook).to eq("rain Mon")
        expect(Buddy::TodayBriefing.week_line(nil)).to be_nil
        expect(Buddy::TodayBriefing.flagged_days("rain Thu, Fri, Sat & Sun")).to eq(%w[Thu Fri Sat Sun])
      end

      describe "whether the briefing already said it" do
        let(:days)  { Buddy::TodayBriefing.flagged_days("rain Thu") }
        let(:today) { Date.new(2026, 8, 26) } # a Wednesday

        def said?(body)
          Buddy::TodayBriefing.week_said?(body, days, today: today)
        end

        it "counts a weather sentence naming the day, however it is named", :aggregate_failures do
          [
            "Rain rolling in Thu, so get the plunge in early.",
            "Thursday looks wet.",
            "Wet one tomorrow, so an early start is worth it.",
            "Rain Thu, and there's a dinner that evening too.",
            # The home half of a sentence that adds the canyon after it.
            "Rain Thu and Fri here, and Alpine's wet too.",
            "Alpine is soaked tomorrow morning. Rain here Thu and Fri as well.",
          ].each { |body| expect(said?(body)).to be(true), body }

          weekend = Buddy::TodayBriefing.flagged_days("rain Sat & Sun")
          expect(Buddy::TodayBriefing.week_said?("Rain over the weekend.", weekend, today: today)).to be(true)
          expect(Buddy::TodayBriefing.week_said?("Quiet one.", [], today: today)).to be(true)

          both = "This week's got rain on Monday and Tuesday, and Alpine's following that " \
                 "same beat, with Monday at 86% and Tuesday at 52%."
          mon_tue = Buddy::TodayBriefing.flagged_days("rain Mon & Tue")
          expect(Buddy::TodayBriefing.week_said?(both, mon_tue, today: Date.new(2026, 9, 24))).to be(true)
        end

        it "does not count a day word that isn't a heads-up about home weather", :aggregate_failures do
          [
            "High of 91°F today, low of 69°F, with a 20% chance of rain.",
            "Serenity is Monday this week.",
            "Nyjah Dinner on Thu at 6:30 PM.",
            "There's a little art show tomorrow evening.",
            "Dinner is Thu. Bit of rain around at some point.",
            "- Dinner Thu at 6:30\n- Groceries after",
            "Alpine looks rainy tomorrow from 8:00 AM to 1:00 PM, and the rest of the " \
            "week there's rain odds on Monday, Thu, and Fri.",
            "Horsetail Falls is looking wet Thu and Fri.",
            # With no clause boundary in front of it the canyon owns the forecast.
            "Rain Thu and Fri up Alpine.",
          ].each { |body| expect(said?(body)).to be(false), body }
        end

        it "needs every one of several flagged days, each in a weather sentence", :aggregate_failures do
          three = Buddy::TodayBriefing.flagged_days("rain Wed, Thu & Fri")
          check = ->(body) { Buddy::TodayBriefing.week_said?(body, three, today: Date.new(2026, 9, 15)) }

          expect(check.call("Thursday's rain is sitting at 79%, and Friday's is at 98%.")).to be(false)
          expect(check.call("Rain Wed, Thu, and Fri this week.")).to be(true)
          expect(check.call("Rain lands Wednesday. Thursday's rain is at 79%, and Friday's at 98%.")).to be(true)
          expect(check.call("Rain lands Wednesday. Thursday and Friday too.")).to be(false)
        end

        it "fills in a range of days and checks every flagged day against it", :aggregate_failures do
          sunday = Date.new(2026, 10, 11)
          ranged = ->(body, flags) {
            Buddy::TodayBriefing.week_said?(body, Buddy::TodayBriefing.flagged_days(flags), today: sunday)
          }

          expect(ranged.call("The week stays soaked: rain Sunday through Thursday.", "rain Sun, Mon, Tue, Wed & Thu")).to be(true)
          expect(ranged.call("Rain Friday through Tuesday.", "rain Fri, Sat, Sun, Mon & Tue")).to be(true)
          expect(ranged.call("Rain Mon-Wed this week.", "rain Mon, Tue & Wed")).to be(true)
          expect(ranged.call("Rain Sunday through Tuesday.", "rain Sun, Mon, Tue & Thu")).to be(false)
          expect(ranged.call("Board meeting Monday through Thursday.", "rain Mon, Tue, Wed & Thu")).to be(false)
        end
      end
    end
  end

  describe "the odds on Alpine's week" do
    # As Buddy::PlungeAdvisor.loose_rain writes them.
    let(:lines) {
      [
        "tomorrow 8am-1pm",
        "Monday, rain at 27% - the forecast has no hours that far out, so the day on its own is the whole of it",
        "Thursday, rain at 100% - the forecast has no hours that far out, so the day on its own is the whole of it",
      ]
    }

    def missing(body)
      Buddy::TodayBriefing.week_odds_missing(body, lines)
    end

    it "reads the day and the figure off day-level lines only", :aggregate_failures do
      expect(Buddy::TodayBriefing.alpine_week_odds(lines).pluck(:pop)).to eq(%w[27 100])
      expect(Buddy::TodayBriefing.alpine_week_odds(["tomorrow 8am-1pm"])).to be_empty
      expect(Buddy::TodayBriefing.week_odds_missing("Quiet one.", [])).to be_empty
    end

    # Unlike week_said?, every figure must be given: the missing one is as
    # likely to be the 100%.
    it "names each figure the briefing left out", :aggregate_failures do
      [
        ["The rest of the week there's rain odds on Monday and Thursday.", %w[27 100]],
        ["Alpine has a 27% chance Monday, and the rest of the week is wet.", %w[100]],
        ["Monday sits at 27 percent and Thursday is 100 percent.", []],
        ["A 127% effort on Monday.", %w[27 100]],
      ].each { |body, pops| expect(missing(body).pluck(:pop)).to eq(pops), body }
    end

    it "composes a line out of only the days that went missing", :aggregate_failures do
      expect(Buddy::TodayBriefing.week_odds_line(missing("Alpine has a 27% chance Monday.")))
        .to eq("In Alpine, Thursday rain at 100%.")
      expect(Buddy::TodayBriefing.week_odds_line(missing("Monday is 27% and Thursday 100%."))).to be_nil
    end

    describe "writing the figure in rather than under" do
      def written(body, avoid: [])
        Buddy::TodayBriefing.with_week_odds_written_in(body, missing(body), avoid: avoid)
      end

      it "puts each figure against the day already named in a weather sentence", :aggregate_failures do
        [
          [
            "Monday looks rainy up there, but only at the day level.",
            [],
            "Monday (27%) looks rainy up there, but only at the day level.",
            %w[100]
],
          [
            "Rain is around Monday and again Thursday.",
            [],
            "Rain is around Monday (27%) and again Thursday (100%).",
            []
],
          ["Rain is around Monday.", [], "Rain is around Monday (27%).", %w[100]],
          # A canyon figure must not land in a sentence about the home week.
          [
            "Rain is around Monday and again Thursday.",
            %w[Mon],
            "Rain is around Monday and again Thursday (100%).",
            %w[27]
],
          [
            "Monday has the dentist at 9am. Rain is around Thursday.",
            [],
            "Monday has the dentist at 9am. Rain is around Thursday (100%).",
            %w[27]
],
          ["Rain is around Monday at 30% there.", [], "Rain is around Monday at 30% there.", nil],
        ].each { |body, avoid, text, unplaced|
          out, left = written(body, avoid: avoid)
          expect(out).to eq(text)
          expect(left.pluck(:pop)).to eq(unplaced) if unplaced
        }

        _, left = written("Rain is around Monday.")
        expect(Buddy::TodayBriefing.week_odds_line(left)).to eq("In Alpine, Thursday rain at 100%.")
      end
    end
  end

  describe "Alpine's rain hours" do
    def missing(body, windows) = Buddy::TodayBriefing.rain_hours_missing(body, windows)

    it "reads each window's start however its meridiem is written", :aggregate_failures do
      [
        ["Rain is in the forecast for Alpine.", ["3-6pm"], ["3-6pm"]],
        ["Rain is in the forecast.", ["11am-2pm"], ["11am-2pm"]],
        ["Rain from 11am.", ["11am-2pm"], []],
        ["Alpine rain 3-6pm.", ["3-6pm"], []],
        ["Alpine rain from 3 to 6pm.", ["3-6pm"], []],
        ["Alpine rain from 3pm.", ["3-6pm"], []],
        ["A high of 73-ish.", ["3-6pm"], ["3-6pm"]],
        # An agenda item at the same o'clock is not a forecast.
        ["Thursday has your iCapital interview at 10am. Rain in Alpine 7-9am.", ["7-9am", "10am-3pm"], ["10am-3pm"]],
      ].each { |body, windows, out| expect(missing(body, windows)).to eq(out), body }
    end

    it "names only the window that went missing" do
      windows = ["11am-3pm", "5-6pm", "7pm-12am", "2-3am"]
      body    = "Rain off and on from 11am to 3pm, again 5pm to 6pm, and 7pm to midnight."

      expect(missing(body, windows)).to eq(["2-3am"])
      expect(Buddy::TodayBriefing.rain_hours_line(missing(body, windows))).to eq("Rain in Alpine 2-3am.")
    end

    it "checks the week's timed hours, and only the timed ones", :aggregate_failures do
      day_level = "Monday, rain at 27% - the forecast has no hours that far out, so the day on its own is the whole of it"
      hours = ->(body, lines) { Buddy::TodayBriefing.week_hours_missing(body, lines).map { |m| m[:window] } }

      expect(hours.call("Thursday has your iCapital interview at 10am.", ["tomorrow, rain 10am-3pm"])).to eq(["10am-3pm"])
      expect(hours.call("Tomorrow Alpine gets rain from 1 to 7pm.", ["tomorrow, rain 1-7pm"])).to be_empty
      expect(hours.call("Quiet.", [day_level])).to be_empty
    end

    it "composes the week line out of missing hours and missing odds", :aggregate_failures do
      [
        [
          ["tomorrow, rain 7-9am", "Tuesday, rain at 62% - no hours that far out"],
          "Morning!",
          "In Alpine, rain tomorrow 7-9am and Tuesday rain at 62%."
],
        [
          ["tomorrow, rain 1-7pm", "Friday, rain at 60% - the forecast has no hours that far out, so the day on its own is the whole of it"],
          "Friday looks 60% wet in Alpine.",
          "In Alpine, rain tomorrow 1-7pm."
],
      ].each { |lines, body, line|
        hours = Buddy::TodayBriefing.week_hours_missing(body, lines)
        odds  = Buddy::TodayBriefing.week_odds_missing(body, lines)

        expect(Buddy::TodayBriefing.week_odds_line(odds, hours)).to eq(line)
      }
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
      expect(Buddy::PlungeAdvisor.briefing_lines(user, now: tz.parse("2026-07-28 15:00"))).to be_empty
    end
  end
end
