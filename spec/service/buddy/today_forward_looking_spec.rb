require "rails_helper"

# The "Today" briefing must be forward-looking: passed agenda items are flagged,
# the day's weather drops once it's late, and the plunge advisor only speaks to
# FUTURE rain.
RSpec.describe "Buddy Today forward-looking" do
  let(:user) { create(:user) }
  let(:tz)   { ActiveSupport::TimeZone["America/Denver"] }

  before { allow(user).to receive(:timezone).and_return("America/Denver") }

  # One of everything, in the shape Buddy::GPT::ContextTool hands over after the
  # briefing filters have run.
  #
  # Every subject block in the seed is gated on the DAY now — Rocco, 2026-09-04:
  # "if there are no chores that day, we don't even mention the chores section
  # in the prompt at all" — so a spec asserting that a RULE reaches the model
  # needs the thing that rule is about to actually be on the day.
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

  def a_full_day!
    allow(Buddy::Features).to receive(:enabled?).and_call_original
    allow(Buddy::Features).to receive(:enabled?).with(user, :chores).and_return(true)
    allow(Buddy::BriefingFacts).to receive(:build).and_return(full_day_facts)
  end

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
  # Rocco, 2026-09-04: "the recent briefings have started to become robotic -
  # there is a cute good morning message, but then in order to enforce having
  # the correct data, we're just injecting the flat data instead of giving
  # everything to Byte to summarize. Maybe we should do more logic in collecting
  # the data and then passing that to Byte and letting him go over it all,
  # instead. And update the prompts to be more dynamic."
  #
  # The evidence is unarguable. On 4 Sep all three briefings - three different
  # people, three different companions - ended with the same two sentences, byte
  # for byte: "High of 86°F today, low of 65°F, with wind worth knowing about."
  # and "Rain Mon, windy Sun this week." That is one repair function printing
  # one string three times, with a single warm paragraph above it.  # Rocco, 2026-09-04: "Having a service that collects and provides all of the
  # data points and then just passing it to the buddy to talk about and phrase
  # in their own words and not have to use any tools is a complete refactor."
  #
  # The evidence for it is unarguable. On 4 Sep all three briefings — three
  # different people, three different companions — ended with the same two
  # sentences, byte for byte: "High of 86°F today, low of 65°F, with wind worth
  # knowing about." and "Rain Mon, windy Sun this week." That is one repair
  # function printing one string three times, under the single warm paragraph
  # that was the only part any model actually wrote.
  #
  # So the deciding happens in Buddy::BriefingFacts, in Ruby, and the prompt
  # says how to SOUND.
  describe "the day, handed over rather than described" do
    let(:seed) { Buddy::TodayBriefing.seed(user) }

    before { a_full_day! }

    it "puts the day in the seed instead of rules for finding it" do
      expect(seed).to include("ON TODAY")
      expect(seed).to include("their day, already gathered and narrowed for you")
    end

    it "puts each thing on one line, in the order of the day" do
      expect(seed).to include("- 11:40 AM · Eye Follow Up · Draper · leave by 11:08 AM (22 min drive)")
    end

    # Stapled on the end as its own paragraph is exactly what `with_leave_times`
    # was doing on 4 Sep, to two of the three briefings.
    it "keeps the departure with the thing it's a departure for" do
      expect(seed).not_to match(/^Eye Follow Up: leave by/)
    end

    # Prod 3954, 19 Aug: "a very open day ahead, with nothing pressing" at 8:30,
    # with two reminders due at 9:00 and one at 10:00, all of which rang. A
    # reminder is a thing that is going to happen to them at a time, so it sits
    # in the day like anything else.
    it "gives a reminder the same shape as an event" do
      expect(seed).to include("ALSO DUE TODAY")
      expect(seed).to include("- Fri 3:00 PM · Do the dishes.")
    end

    # Rocco, 2026-09-04: "I still want Buddy to say 'It's trash day' instead of
    # 'You have a trash job today'." The group isn't a task with a name, it's
    # what the day IS.
    it "asks for a group of jobs to be said as the day, not as a task" do
      expect(seed).to include("the job is what the DAY is")
      expect(seed).to include("it's trash day")
    end

    it "gives chores as the job rather than as the rows" do
      expect(seed).to include("JOBS TODAY")
      expect(seed).to include("- trash: Gather trash, Take out trash bags")
      expect(seed).to include("- Replace the air filter · 5x")
    end

    it "keeps the week to its own short list" do
      expect(seed).to include("LATER THIS WEEK")
      expect(seed).to include("- tomorrow · 6:00 PM · Drinks out")
    end

    # Rocco, 2026-09-04: "'You have yoga tomorrow' is absolutely incorrect.
    # 'Chelsea has yoga tomorrow' is accurate and acceptable." The owner leads
    # the title, so the row reads as hers before the model has written a word.
    it "puts whose it is in front of what it is" do
      expect(seed).to include("- 4:00 PM · Chelsea: Her thing")
    end

    it "marks a thing that isn't happening" do
      expect(seed).to include("cancelled")
    end

    it "marks a thing with no clock time as all day" do
      expect(seed).to include("all day")
    end
  end

  # The stubbed facts above test the writing; this is the wiring. `BriefingFacts`
  # reads through ContextTool on purpose, so what the seed says the day holds
  # and what the filters would answer are the same answer.
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

    it "names what is actually on the day" do
      seed = Buddy::TodayBriefing.seed(user, conversation)

      expect(seed).to include("Eye Follow Up")
      expect(seed).to include("trash: Gather trash, Take out trash bags")
    end

    it "reads the same rows the briefing filters would hand over" do
      facts  = Buddy::BriefingFacts.build(user, conversation)
      served = Buddy::GPT::ContextTool.new(user, conversation, briefing: true).filtered([:chores_due_today])

      expect(facts[:jobs].pluck(:name)).to eq(served[:chores_due_today].pluck(:name))
    end

    # The seed the model reads and the facts a pre-send repair checks it against
    # have to be the same day, or the repair is arguing with a different
    # briefing. `deliver!` stamps them on the message.
    it "rides on the message, for the repairs to read back" do
      allow(BuddyDeliverWorker).to receive(:perform_async)
      allow(MonitorChannel).to receive(:broadcast_to)

      msg = Buddy::TodayBriefing.deliver!(user, conversation, scheduled: false)

      expect(msg.metadata["briefing"]["jobs"].pluck("name")).to include("Gather trash")
    end
  end

  # A rule about partners' calendars on a day with no partner item in it teaches
  # the model to go looking for something that isn't there, and a prompt full of
  # inapplicable sections is most of what makes a briefing read like a form
  # being filled in.
  describe "what a quiet day's prompt leaves out" do
    let(:quiet) {
      allow(Buddy::BriefingFacts).to receive(:build).and_return(
        name: "Rocco", today: [], due: [], jobs: [], week: [], stash: [], weather: {}, alpine: {},
      )
      Buddy::TodayBriefing.seed(user)
    }

    it "says there is nothing rather than printing empty headings" do
      expect(quiet).not_to include("ON TODAY")
      expect(quiet).to include("Nothing came back for today")
    end

    it "drops the guidance for jobs, reminders and partners" do
      expect(quiet).not_to include("Jobs listed under one name")
      expect(quiet).not_to include("somebody else's")
    end

    it "drops the week, the stash, the all-day rule and the travel rule" do
      expect(quiet).not_to include("The week gets at most one line")
      expect(quiet).not_to include("things on their mind")
      expect(quiet).not_to include("simply ON today")
      expect(quiet).not_to include("A leave-by is a clock time")
    end

    # The half about how to SOUND and the half about naming things both stay:
    # neither has a subject that can be absent from a day.
    it "keeps the voice and the rules that always apply" do
      expect(quiet).to include("Tight, not truncated")
      expect(quiet).to include("OPEN WITH A GREETING")
      expect(quiet).to include("Call each thing by its name")
    end

    it "is a great deal shorter than a full day's" do
      a_full_day!
      full = Buddy::TodayBriefing.seed(user)

      expect(quiet.length).to be < (full.length * 0.8)
    end
  end

  describe "the briefing it asks for" do
    let(:seed) { Buddy::TodayBriefing.seed(user) }

    before { a_full_day! }

    # THE rule for this file. Every concrete example ever written into this
    # prompt came back out of it: two agenda items were named here purely as
    # what-NOT-to-say illustrations, and both were read out by name on the days
    # they came round. Naming a thing in order to forbid it still puts the name
    # in front of the model.
    #
    # The day's own rows are exempt, obviously — they're the message. What must
    # stay out is anything ILLUSTRATIVE.
    it "hands the model no example it can echo" do
      instructions = seed.split("HOW TO SAY IT").last

      expect(instructions.scan(/"[^"\n]{25,}"/)).to be_empty
      expect(instructions.scan(/`([A-Z][A-Za-z0-9' .-]{3,40})`/).flatten - ["Part of day"]).to be_empty
    end

    # Rocco, 2026-09-04, on "notes to write FROM, not lines to read out":
    # "Isn't this a type of anti-example? We should tell what TO do, not what
    # NOT to do?" And then, on the replacement for it: "'leave the rows out of
    # it' - isn't that an anti-example again?"
    #
    # He was right twice, so this stops being something he has to catch.
    it "says what to do with the day rather than what not to do" do
      expect(seed).to include("reframe it in your own words and pass it on")
      expect(seed).not_to include("not lines to read out")
    end

    # Every instruction is a sentence about what to write. The test is whether
    # the positive half already specifies the output: where it does, the
    # negation is doing nothing except naming the thing again, which is the
    # subtraction test this prompt applies to Buddy's own writing turned back on
    # the prompt itself.
    #
    # The four that stay are all load-bearing rather than decorative, and each
    # is here by name so a fifth can't slip in behind them:
    #   - "Only what's above" and "it isn't happening today" — the invented-item
    #     guard, which has no positive form.
    #   - "Tight, not truncated" — the contrast IS the rule; the positive half
    #     alone reads as permission to cut.
    #   - "keep em dashes out of it" — a typographic ban with nothing to say
    #     positively.
    #   - "leave it out" on the emoji — the outcome of a decision procedure, not
    #     a style prohibition.
    it "carries no instruction whose negative half is doing the work" do
      allowed = [
        "Only what's above",
        "it isn't happening today",
        "Tight, not truncated",
        "keep em dashes out of it",
        "leave it out",
      ]
      instructions = seed.split("HOW TO SAY IT").last.split("\n").reject { |line|
        allowed.any? { |phrase| line.include?(phrase) }
      }

      expect(instructions.join("\n")).not_to match(/\b(?:never|don't|do not|rather than|instead of|leave .* out of it)\b/i)
    end

    it "says the filtering is already done rather than how to do it" do
      expect(seed).to include("already gathered and narrowed for you")
      expect(seed).to include("nothing to look up and nothing to work out")
    end

    # A brief mention still has to be specific: compressing an item to its
    # category strips the only part that couldn't have been guessed.
    it "refuses a bare category where the item has a name" do
      expect(seed).to include("Call each thing by its name")
      expect(seed).to include("the part they couldn't have guessed")
    end

    # The old rule said brevity meant "mentioning FEWER things", with a 3-5 line
    # cap in two other places. That is an instruction to drop real items on a
    # busy day, and it costs exactly the ones worth having.
    it "puts no cap on how many lines a day is allowed to be" do
      expect(seed).to include("Trim the words around a thing and keep the thing")
      expect(seed).not_to match(/three to five|3-5|3 to 5/i)
      expect(seed).not_to match(/mentioning FEWER things/i)
    end

    # Brevity still means something: it comes out of the words, not the item
    # count, and the padding rule is untouched.
    it "still asks for tight lines and no padding" do
      expect(seed).to include("The test is subtraction")
      expect(seed).to include("Tight, not truncated")
    end

    # Prod: "The only thing to do today is Espresso" — Espresso was 5x that day,
    # so it was the only chore that cleared the exception bar. The rotation is
    # deliberately withheld, which makes a short list a statement about what is
    # UNUSUAL. Nothing in the prompt invites reading it as the whole day now:
    # the jobs are one section of a day that also has events and reminders in
    # it, and the rule for them is only about saying them once.
    it "asks for a job to be said once, as the job" do
      expect(seed).to include("Jobs listed under one name are one job")
      expect(seed).to include("trash day")
    end

    it "treats a multiplier as something worth some enthusiasm" do
      expect(seed).to include("worth well above the usual today")
    end

    it "asks for an emoji that's about something" do
      expect(seed).to include("has to be ABOUT something")
    end

    it "asks for odd clock times to be rounded" do
      expect(seed).to include("Round odd clock times")
    end

    # Prod 3951 opened by weighing his calendar against his partner's, and named
    # her 4pm meeting on the strength of it maybe mattering later. The three
    # paragraphs that used to decide WHICH of her items to raise are gone — the
    # deciding happens before the model sees any of them — so what's left is one
    # line about what to do with the ones that arrive.
    describe "a partner's calendar" do
      it "asks for it to be said as theirs, by name" do
        expect(seed).to include("is that person's")
        expect(seed).to include("who, what, when")
        expect(seed).to include("news about somebody they care about")
      end

      # The names in this house are real, and every illustration ever written
      # into this prompt has come back out of it on a day it didn't fit. The
      # shape is the rule; there is no worked example of it.
      it "shows no sample sentence with a name in it" do
        expect(seed.split("HOW TO SAY IT").last).not_to match(/"[A-Z][a-z]+ has /)
      end

      it "no longer argues about the ones it will never be handed" do
        expect(seed).not_to include("A hedge is not an effect")
        expect(seed).not_to include("mine: false")
      end
    end

    # Announcing the briefing instead of writing it is the one failure that
    # leaves them holding nothing. It used to be said twice, in the negative,
    # at both ends of a two-thousand-word prompt. It's the opening sentence now,
    # in the positive, where nothing can bury it.
    it "opens by saying the message IS what it writes" do
      expect(seed.lines.first).to include("what you write IS the message")
      expect(seed.lines.first).to include("nothing follows it")
    end

    it "drops the whole jobs section for someone without chores" do
      allow(Buddy::Features).to receive(:enabled?).with(user, :chores).and_return(false)
      allow(Buddy::BriefingFacts).to receive(:build).and_return(
        name: "Rocco", today: [], due: [], jobs: [], week: [], stash: [], weather: {}, alpine: {},
      )

      bare = Buddy::TodayBriefing.seed(user)

      expect(bare).not_to include("JOBS TODAY")
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
    let(:conversation) { user.byte_conversations.create!(mode: :buddy) }

    # Prod 4980: Byte's briefing OPENED on "Whisper nap sound just went off" —
    # a reminder that had fired twenty hours earlier — and then named nothing
    # still ahead. It used to take three bullets of prose to keep a rung
    # reminder and a passed item out of the message, and both bullets lost on
    # days it mattered.
    #
    # There is no rule to lose now. `BriefingFacts` keeps only what's still
    # ahead, so a thing that already happened is not in the seed at all and the
    # model has nothing to read out.
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
      facts = { name: "Rocco", today: [], due: [], jobs: [], week: [], stash: [], weather: {}, alpine: {} }
      allow(Buddy::GPT::ContextTool).to receive(:new).and_return(
        instance_double(
          Buddy::GPT::ContextTool,
          filtered: { today_notable: [{ time: "8:00 AM", title: "Gone already", passed: true }] },
        ),
      )

      expect(Buddy::BriefingFacts.build(user, conversation)[:today]).to be_empty
      expect(facts[:today]).to be_empty
    end

    # The prompt no longer names the statuses at all. It named them so it could
    # explain what they were FOR, and that only mattered while the rows were in
    # front of the model.
    it "spends no prompt on statuses the model will never see" do
      seed = Buddy::TodayBriefing.seed(user, conversation)

      expect(seed).not_to include("already_rang")
      expect(seed).not_to include("passed")
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

    # Prod 4529, 25 Aug: "You've got Yoga first this morning, with a pretty full
    # drive time before it", sent at 8:25 to somebody who had to walk out at
    # 8:46, and neither figure in it. The clock time is the part they can act on
    # without doing the arithmetic, so the rule asks for it in the sentence that
    # names the thing rather than as a category of information.
    it "asks for the departure as a clock time, beside the thing it belongs to" do
      a_full_day!
      seed = Buddy::TodayBriefing.seed(user)

      expect(seed).to include("A leave-by is a clock time to walk out of the door")
      expect(seed).to include("Say it in the same sentence that names the thing")
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

    it "carries the figures in the morning" do
      expect(weather_at("08:00")).to include(high: 88, low: 61)
      expect(seed_at("08:00")).to include("High 88°F, low 61°F")
    end

    # Six briefings running across two mornings carried the forecast and said
    # nothing about the weather at all. The block was worded as an option
    # ("weave it in naturally", "skip the today line if it's unremarkable") and
    # that is how it was taken; rewording it to "give me the high and the low"
    # lost three more times. It is a rule now, and it is the only line in the
    # prompt written in capitals.
    it "asks for the figures as a rule rather than leaving it to taste" do
      seed = seed_at("08:00")

      expect(seed).to include(Buddy::TodayBriefing::WEATHER_DIRECTIVE)
      expect(seed).not_to include("weave it in naturally")
    end

    # And then the rule failed too - eight briefings running. So Buddy::GPT::Turn
    # composes the line and puts it on when the model didn't, and it decides
    # whether weather was asked for by looking for that exact directive in the
    # seed. The two have to stay in step: reword the rule without the constant
    # and the repair silently stops firing.
    it "carries the directive the repair keys off" do
      expect(Buddy::TodayBriefing.weather_ordered?(seed_at("08:00"))).to be(true)
    end

    # Late in the day the figures are dropped on purpose, and a repair that
    # fired anyway would put a high back onto the one briefing that decided the
    # high no longer mattered.
    it "drops the figures in the evening and keeps the week" do
      expect(weather_at("21:00")).to eq(week: "rain Thu")
      expect(Buddy::TodayBriefing.weather_ordered?(seed_at("21:00"))).to be(false)
      expect(seed_at("21:00")).to include("This week: rain Thu")
    end

    # `summary` has never carried wind, so a day of hard gusts reached the seed
    # reading "currently 72°F, clear" and nothing more.
    it "carries the notable thing the figures have no room for" do
      allow(WeatherService).to receive(:today_figures).and_return(high: 88, low: 61, rain: 10, notable: "windy")

      expect(seed_at("08:00")).to include("- windy")
    end

    it "adds nothing on a day with nothing notable in it" do
      expect(seed_at("08:00")).not_to include("- windy")
    end

    # A phrase quoted in order to forbid it is still a phrase handed over, and
    # it has come back out of the model as a suggestion more than once.
    it "hands over no phrase to avoid" do
      expect(seed_at("08:00")).not_to match(/layers|coat|umbrella|what to wear/i)
    end

    # Off-prod, or with no API key, there's simply no forecast. Say nothing
    # rather than print a heading with nothing under it.
    it "is empty when there's no weather to be had" do
      allow(WeatherService).to receive_messages(today_figures: nil, week_outlook: nil)

      expect(weather_at("08:00")).to eq({})
      expect(seed_at("08:00")).not_to include("WEATHER")
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

    # The closing read-back is gone. It existed because the middle of a
    # two-thousand-word prompt is where a rule goes to be forgotten, and there
    # is no middle any more: what's left is short enough that a rule stated once
    # is a rule in front of the model.
    it "no longer needs a closing read-back to survive its own length" do
      seed = Buddy::TodayBriefing.seed(user)

      expect(seed).not_to include("BEFORE YOU SEND")
      expect(seed.length).to be < 6_000
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
