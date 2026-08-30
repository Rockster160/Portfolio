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
    end

    # The old rule said brevity meant "mentioning FEWER things", with a 3-5 line
    # cap in two other places. That is an instruction to drop real items on a
    # busy day, and it costs exactly the ones worth having — everything reaching
    # the model is already narrowed to the exceptions, so there is nothing left
    # in it that is safe to leave out. Length follows the day now.
    it "puts no cap on how many lines a day is allowed to be" do
      expect(seed).to include("SAY EVERYTHING UNUSUAL")
      expect(seed).to match(/never about how many things get named/)
      expect(seed).not_to match(/three to five|3-5|3 to 5/i)
      expect(seed).not_to match(/mentioning FEWER things/i)
    end

    # Brevity still means something: it comes out of the words, not the item
    # count, and the padding rules are untouched.
    it "still asks for tight lines and no padding" do
      expect(seed).to include("Cut PADDING")
      expect(seed).to include("Tight, not truncated")
    end

    # Prod: "The only thing to do today is Espresso" — Espresso was 5x that day,
    # so it was the only chore that cleared the exception bar. The dailies are
    # deliberately withheld, which makes a one-item list a statement about what
    # is UNUSUAL, and reading it as the whole day is how the rest of it gets
    # forgotten.
    it "forbids calling the chore list everything they have to do" do
      allow(Buddy::Features).to receive(:enabled?).and_call_original
      allow(Buddy::Features).to receive(:enabled?).with(user, :chores).and_return(true)

      expect(seed).to match(/NOT everything they have to do today, and you must never say it is/)
      expect(seed).to match(/never count it, total it, or call it all there is/)
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

    # Prod 3954, 19 Aug: "a very open day ahead, with nothing pressing" at 8:30,
    # with two reminders due at 9:00 and one at 10:00, all of which rang. The
    # seed said which reminders to leave OUT and never once said they belong in.
    it "says a still-due reminder is part of the day, not just which ones to drop" do
      expect(seed).to include("`upcoming_reminders` is the OTHER HALF of the day")
      expect(seed).to include("a day with three of them on it is not an open day")
    end

    # Rocco, 2026-08-28: "We don't want Byte to include all of the every-day
    # reminders in the briefing as it fills it with extra text that's not
    # needed." The cut itself is in Buddy::GPT::ContextTool; this only tells the
    # model that what it's holding has already been narrowed, so it doesn't
    # spend a sentence explaining an absence.
    it "says the everyday reminders have already been taken out" do
      expect(seed).to include("Everything that goes off every day or every weekday has been taken out")
      expect(seed).to include("the standing repeats, the everyday reminders and the everyday chores")
    end

    # Prod 3951 opened by weighing his calendar against his partner's, and named
    # her 4pm meeting on the strength of it maybe mattering later. The rules
    # already forbade naming her items; they said nothing about framing his day
    # by hers, and nothing about what counts as a reason.
    describe "a partner's calendar" do
      it "is never the frame for their own day" do
        expect(seed).to include("My day is never described by comparison to theirs")
        expect(seed).to include("How full their day is isn't a fact about mine")
      end

      # The three paragraphs deciding WHICH of a partner's items to raise are
      # gone, because the deciding is done before the model sees any of them -
      # ContextTool::PARTNER_FILTERED uses the overlap to decide which survive
      # and then strips the marker, so what arrives is background with nothing
      # to compare itself to.
      # A rule about picking from a set that has already been picked from is
      # the thing that makes a long prompt longer and no better.
      it "explains the ones that do arrive rather than filtering them again" do
        expect(seed).to include("BACKGROUND, not a demand on me")
        expect(seed).to include("has already been taken out")
      end

      it "no longer argues about the ones it will never be handed" do
        expect(seed).not_to include("A hedge is not an effect")
        expect(seed).not_to include("`leave_by` or a `drive_min` off an item tagged `mine: false`")
      end
    end

    # The seed said four different things about length in four places, and one
    # of them ("the few things you do name") was left over from a line cap that
    # had already been removed for costing real items on a busy day.
    describe "rules that were stated more than once" do
      it "no longer contradicts itself about how much to name" do
        expect(seed).not_to match(/few things you do name/i)
        expect(seed).to include("SAY EVERYTHING UNUSUAL")
      end

      it "keeps every consolidated rule somewhere" do
        expect(seed).to include("A vague gesture at a busy morning")
        expect(seed).to include("That is a correct briefing, not a failed one")
        expect(seed).to match(/Lead with|LEAD WITH/)
        expect(seed).to include("most unlike an ordinary day")
      end

      # Not consolidated, deliberately. Announcing the briefing instead of
      # writing it is the one failure that leaves them holding nothing, and it
      # is worth saying at both ends.
      it "still says twice that the briefing is never announced" do
        expect(seed.scan(/on its way|is finished, on its way/).length).to be >= 2
      end
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

  # Three briefings across two days read something already finished back to the
  # person whose day it was, each from a different context key:
  #
  #   3796 (Suki, 8/15) named "leave for work at 9:20 AM" at 12:03 PM and said
  #         in the same breath that it had already passed.
  #   3824 (Suki, 8/16) recapped two of Saturday's reminders, both rung.
  #   3825 (Moss, 8/16) opened the chore subject purely to report there was
  #         nothing in it.
  #
  # The flags were all correct in context every time; what was missing was any
  # instruction about what they're FOR. The reminder statuses in particular were
  # never named anywhere in the briefing prompt, so the model got two rows
  # labelled already-rung, no rule, and did the obvious thing with them.
  describe "things that are already done" do
    let(:seed) { Buddy::TodayBriefing.seed(user) }

    # Half of this is a fact about context rather than the prompt: the rule can
    # only be written against a key that actually arrives.
    it "gets rung reminders in context to have a rule about" do
      conversation = user.byte_conversations.create!(mode: :buddy)
      BuddyReminder.create!(
        user: user, byte_conversation: conversation,
        body: "Finish cleaning the car.", fire_at: 20.hours.ago, fired_at: 20.hours.ago
      )

      reminders = Buddy::Context.build(user, conversation)[:upcoming_reminders]

      expect(reminders.pluck(:status)).to include(:already_rang)
    end

    it "says what a rung reminder is there for" do
      expect(seed).to include("already_rang")
      expect(seed).to match(/status: off/)
    end

    # The lever both audits pointed at: a bare prohibition in a list of bullets
    # lost, and the `mine: false` bullet that got this shape held.
    it "tells it to leave a passed item out rather than only not to recap it" do
      expect(seed).to include("Default to leaving them out entirely")
    end

    it "closes the passing-mention loophole a bare prohibition leaves open" do
      expect(seed).to match(/not as a count/)
    end

    # Prod 3951 led Rocco's briefing with Chelsea's 11:30 block AND its 10:50
    # leave-by, then tagged her 4:00 correctly one sentence later. Both halves
    # are answered in data now rather than in prose: `tag_ownership` strips the
    # departure time off a shared-in item, and the item itself only reaches a
    # briefing when it collides with something of theirs.
    it "leaves the departure time to the pipe that already removes it" do
      expect(seed).not_to match(/Never give me a `leave_by`/)
    end

    # Byte's briefing the same morning got this right by simply not raising the
    # subject, so the fix is the clause, not the pipe.
    it "tells it an empty chore list is not something to report" do
      allow(Buddy::Features).to receive(:enabled?).and_call_original
      allow(Buddy::Features).to receive(:enabled?).with(user, :chores).and_return(true)

      expect(seed).to include("default to leaving the subject out entirely")
    end
  end

  # Prod 3823 raised the travel on two items and gave a figure for neither:
  # "it's a longer drive" and "much closer". Both numbers were in context the
  # whole time (32 and 5 minutes). That's worse than saying nothing — it names
  # a cost and withholds the only part that can be acted on.
  #
  # `drive_min` alone had been there for a while and still asks whoever reads it
  # to subtract. `leave_by` is the answer to the question they'd be subtracting
  # for, and the travel chain has already computed it.
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

    it "hands over the clock time to walk out, not just the minutes" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        item_with_travel!(tz.parse("2026-07-28 09:23"))

        item = Buddy::Context.build(user, conversation)[:today_agenda].first

        expect(item[:drive_min]).to eq(32)
        expect(item[:leave_by]).to eq("9:23 AM")
      end
    end

    # An item with no travel worked out must not carry an empty key for the
    # model to explain.
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

    it "asks for both figures rather than for a sense of distance" do
      seed = Buddy::TodayBriefing.seed(user)

      expect(seed).to include("`leave_by`")
      expect(seed).to include("Both are figures; say the figures")
    end
  end

  describe "weather_block time gating" do
    before do
      allow(WeatherService).to receive_messages(summary: "currently 72°F, clear. today high 88°F.", week_outlook: "rain Thu")
    end

    it "includes today's weather in the morning" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        expect(Buddy::TodayBriefing.weather_block(user)).to include("Today:").and include("currently 72°F, clear")
      end
    end

    # Six briefings running across two mornings carried the forecast in the seed
    # and said nothing about the weather at all. The block was worded as an
    # option ("weave it in naturally", "skip the today line if it's
    # unremarkable") and that is how it was taken.
    #
    # Rewording it to "Give me the high and the low, in one short line" did not
    # hold either: three more briefings dropped it on 21-22 Aug, one of them a
    # day carrying an 89% chance of rain with a named window, to two people.
    # It was the only must-say section in that prompt phrased as a description
    # while every other one was phrased as a rule, so it now reads as a rule -
    # and it is named again in the closing check, because the middle of a prompt
    # that long is where an instruction goes to be forgotten.
    it "asks for the figures as a rule rather than leaving it to taste" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        block = Buddy::TodayBriefing.weather_block(user)
        expect(block).to include("THE HIGH AND THE LOW GO IN")
        expect(block).not_to include("weave it in naturally")
      end
    end

    # And then the rule failed too - three more briefings on 23 Aug, all three
    # carrying the reworded block AND the closing check, eight running. So
    # Buddy::GPT::Turn now composes the line and puts it on when the model
    # didn't, and it decides whether weather was asked for by looking for this
    # exact directive in the seed. The two have to stay in step: reword the
    # block without the constant and the repair silently stops firing.
    it "carries the directive the repair keys off" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        expect(Buddy::TodayBriefing.weather_block(user)).to include(Buddy::TodayBriefing::WEATHER_DIRECTIVE)
        expect(Buddy::TodayBriefing.weather_ordered?(Buddy::TodayBriefing.seed(user))).to be(true)
      end
    end

    # Late in the day the block is empty on purpose, and a repair that fired
    # anyway would put a high back onto the one briefing that decided the high
    # no longer mattered.
    it "does not carry it once the day's weather has been dropped" do
      travel_to(tz.parse("2026-07-28 19:00")) do
        expect(Buddy::TodayBriefing.weather_ordered?(Buddy::TodayBriefing.seed(user))).to be(false)
      end
    end

    describe "the composed line" do
      it "reads the high and the low off the figures" do
        line = Buddy::TodayBriefing.weather_line(high: 93, low: 69, rain: 0, notable: nil)

        expect(line).to eq("High of 93°F today, low of 69°F.")
      end

      it "carries the odds when the day is above the baseline" do
        line = Buddy::TodayBriefing.weather_line(high: 93, low: 69, rain: 56, notable: "rain")

        expect(line).to eq("High of 93°F today, low of 69°F, with a 56% chance of rain.")
      end

      it "says nothing at all without both figures" do
        expect(Buddy::TodayBriefing.weather_line(high: 93, low: nil, rain: 0, notable: nil)).to be_nil
      end
    end

    # 26 Aug: all three seeds carried "This week to flag: rain Thu, Fri, Sat &
    # Sun", Byte's carried an Alpine block reading 99%, 100%, 100% on top of it,
    # and all three briefings went out with no mention of any of it. All three
    # also ended on the identical weather_line string, which is the tell - none
    # of the models wrote weather at all, and only today's half had a fallback.
    describe "the week's flagged days" do
      it "composes a line off the outlook it was given" do
        expect(Buddy::TodayBriefing.week_line("rain Thu, Fri, Sat & Sun"))
          .to eq("Rain Thu, Fri, Sat & Sun this week.")
      end

      it "carries more than one kind of weather" do
        expect(Buddy::TodayBriefing.week_line("snow Mon, windy Fri"))
          .to eq("Snow Mon, windy Fri this week.")
      end

      it "says nothing on an unremarkable week" do
        expect(Buddy::TodayBriefing.week_line(nil)).to be_nil
      end

      it "reads the days back out of the outlook" do
        expect(Buddy::TodayBriefing.flagged_days("rain Thu, Fri, Sat & Sun")).to eq(%w[Thu Fri Sat Sun])
      end

      describe "whether the briefing already said it" do
        let(:days)  { Buddy::TodayBriefing.flagged_days("rain Thu & Fri") }
        let(:today) { Date.new(2026, 8, 26) } # a Wednesday

        def said?(body)
          Buddy::TodayBriefing.week_said?(body, days, today: today)
        end

        it "counts the abbreviation" do
          expect(said?("Rain rolling in Thu, so get the plunge in early.")).to be(true)
        end

        it "counts the whole weekday name" do
          expect(said?("Friday looks wet.")).to be(true)
        end

        # The prompt asks for that word instead of the weekday name for the next
        # day out, so a correct briefing may never write the abbreviation at all.
        it "counts tomorrow, for the day that is tomorrow" do
          expect(said?("Wet one tomorrow, so an early start is worth it.")).to be(true)
        end

        it "counts the weekend for a Saturday or Sunday flag" do
          weekend = Buddy::TodayBriefing.flagged_days("rain Sat & Sun")

          expect(Buddy::TodayBriefing.week_said?("Rain over the weekend.", weekend, today: today)).to be(true)
        end

        it "is not satisfied by today's own forecast" do
          expect(said?("High of 91°F today, low of 69°F, with a 20% chance of rain.")).to be(false)
        end

        it "is not fooled by a day nobody flagged" do
          expect(said?("Serenity is Monday this week.")).to be(false)
        end

        # Prod 4925 and 4930, 29 Aug: both seeds said "rain Sun, Mon, Tue & Wed,
        # windy Fri" and both briefings went out with no forecast at all, on a
        # Saturday carrying rain four days running. Byte wrote "Nyjah Dinner on
        # Monday at 6:30 PM" and Moss "Monday's got Nyjah Dinner at Texas
        # Roadhouse too"; Monday was flagged, the whole-body match counted it,
        # and the repair stood down. 4860 lost its line the same way the
        # morning before, on "a little art show tomorrow evening". The days
        # worth flagging and the days with plans come out of the same week, so
        # this is the ordinary case rather than the rare one.
        it "does not count a day word carrying an appointment" do
          expect(said?("Nyjah Dinner on Thu at 6:30 PM.")).to be(false)
        end

        it "does not count tomorrow when tomorrow is only when something is on" do
          expect(said?("There's a little art show tomorrow evening.")).to be(false)
        end

        it "still counts the day when the weather is in the same sentence" do
          expect(said?("Rain Thu, and there's a dinner that evening too.")).to be(true)
        end

        # The day and the forecast have to be the same claim. Split across two
        # sentences, neither one is a heads-up for that day.
        it "does not count a day and a forecast in separate sentences" do
          expect(said?("Dinner is Thu. Bit of rain around at some point.")).to be(false)
        end

        it "reads a bullet as its own sentence" do
          expect(said?("- Dinner Thu at 6:30\n- Groceries after")).to be(false)
        end

        it "leaves an unremarkable week alone" do
          expect(Buddy::TodayBriefing.week_said?("Quiet one.", [], today: today)).to be(true)
        end
      end
    end

    # The three rules that have each gone out missing, restated where a long
    # prompt actually lands. Asserted on the whole seed rather than the weather
    # block, since that is the thing being read back.
    it "names the three dropped rules again at the end, where they get read" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        closing = Buddy::TodayBriefing.seed(user).split("BEFORE YOU SEND").last

        expect(closing).to include("high and the low")
        expect(closing).to include("called by its name")
        expect(closing).to include("still ahead")
      end
    end

    # A plain sunny day is the baseline and has nothing to say for itself. Only
    # what's genuinely notable adds a line on top of the figures.
    it "makes an ordinary day the baseline rather than a line to fill" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        expect(Buddy::TodayBriefing.weather_block(user)).to include("an ordinary sunny day is the baseline")
      end
    end

    # `summary` has never carried wind, so a day of hard gusts reached the seed
    # reading "currently 72°F, clear" and nothing more.
    it "carries the notable thing the summary has no room for" do
      allow(WeatherService).to receive(:today_notable).and_return("windy")

      travel_to(tz.parse("2026-07-28 08:00")) do
        expect(Buddy::TodayBriefing.weather_block(user)).to include("Notable today: windy.")
      end
    end

    it "adds nothing on a day with nothing notable in it" do
      allow(WeatherService).to receive(:today_notable).and_return(nil)

      travel_to(tz.parse("2026-07-28 08:00")) do
        expect(Buddy::TodayBriefing.weather_block(user)).not_to include("Notable today")
      end
    end

    # A phrase quoted in order to forbid it is still a phrase handed over, and
    # it has come back out of the model as a suggestion more than once. The rule
    # is carried positively or it isn't carried.
    it "hands over no phrase to avoid" do
      travel_to(tz.parse("2026-07-28 08:00")) do
        expect(Buddy::TodayBriefing.weather_block(user)).not_to match(/layers|coat|umbrella|what to wear|don't|do not|never/i)
      end
    end

    it "drops today's weather in the evening, keeps the week outlook" do
      travel_to(tz.parse("2026-07-28 21:00")) do
        block = Buddy::TodayBriefing.weather_block(user)
        expect(block).not_to include("Today:")
        expect(block).not_to include("Give me the high")
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
