module Buddy
  # The "Today" briefing seed + delivery. Fired by the daily reminder carrying
  # the `today_briefing` tool (Buddy::TodaySchedule), and by hand with the
  # `/today` slash command (ByteController#send_today_briefing). The hero chip
  # that used to run one is long gone; comments here said otherwise for a while
  # and sent people looking for a button that isn't there.
  #
  # A turn answering the seed is NOT offered the `today_briefing` tool — see
  # Buddy::Tools::BRIEFING_WITHHELD. It could otherwise send itself another one,
  # forever.
  #
  # The SCHEDULE is a morning thing. The briefing is not — the chip is there all
  # day and gets tapped at all hours, so nothing in the seed may assume which
  # part of the day it's being read in. Anything that needs the hour reads it
  # off the clock (Buddy::Day) or off `Part of day` at the top of the prompt.
  module TodayBriefing
    module_function

    # No sample sentences, no record names, no quoted phrasing to avoid.
    #
    # Every concrete example that has ever been in here came back out in a
    # briefing. Two agenda items were named in this prompt purely as
    # what-not-to-say illustrations, and both were then read out by name on the
    # days they came round. The same happened with the wry asides listed as
    # padding: banning a phrase by quoting it is still handing over a phrase.
    # The rules below describe SHAPES, and nothing in them can be echoed.
    TONE = <<~TONE.strip.freeze
      LAST AND MOST IMPORTANT: this is you talking. Everything above is WHAT to say; this is how it should sound, and a briefing with every fact right and no voice in it has still failed.

      Write it the way you'd catch a friend up on their day, glad to be the one doing it. Open like a person, take the natural phrasing over the clinical one, and where something genuinely earns a reaction, give it one - real interest in a good day is what tells them a friend read this and not a script. Keep it in your register: glad and warm more often than bouncy, always about something specific.

      Make every clause carry something. The test is subtraction, applied to each one you write: cut it, and if they still know everything they knew before, it was decoration. One good observation in a message is yours to keep; one attached to each item in turn is a tic, and it's the loudest way this stops sounding like you. The greeting is exempt - it carries no information by design, and a briefing that opens cold is the failure the rest of this is trying to avoid.

      Put warmth at the FRONT of a line, as a reaction to the thing itself. Torn between flatter and warmer, go warmer: this should sound like someone who likes them.

      Just say the thing, and let the message move from one beat to the next on its own. What joins two beats comes out of what the day is, so no two briefings ever join up the same way.

      Tight, not truncated. Every line earns its place, none of them run long, and the message is however many lines the day actually has in it. Break it into short paragraphs with a blank line between distinct beats so it renders clean and skimmable.

      Commas and short sentences carry the rhythm; keep em dashes out of it.

      An emoji, if you use one, has to be ABOUT something in the message: warmth you actually feel, or a reaction to one specific thing. If it could move to a different day's briefing unchanged, leave it out.
    TONE

    # A Today ALWAYS opens with a hello. There is no branch here and there
    # should never be one again.
    #
    # It started as four paragraphs of "OPEN with a warm greeting WHEN IT FITS",
    # and four of seven briefings over two days either skipped it or landed it
    # flat. The judgement then moved here, where the timestamps are — greet
    # unless they'd spoken in the last 30 minutes — which was still a branch,
    # just a better-informed one, and it was answering the wrong question.
    # Whether a hello fits isn't a fact about how recently anyone spoke: a Today
    # is a THING WITH A SHAPE, and the shape opens with a hello, whether it was
    # asked for at 8am, a second time at noon, or in the middle of a
    # conversation. Two in a row is not a bug.
    #
    # What reaches the model is an instruction with nothing left to weigh.

    # The exact directive, so Buddy::GPT::Turn can tell that the seed really did
    # ask for one before putting a hello on a reply that lacks it.
    GREET_DIRECTIVE = "OPEN WITH A GREETING.".freeze

    def greeting_ordered?(seed_body)
      seed_body.to_s.include?(GREET_DIRECTIVE)
    end

    # Which set of hellos fits the clock, for the fallback in Buddy::GPT::Turn
    # when the model didn't write one of its own. Keyed off the same
    # `part_of_day` the prompt is built from, so the two can't disagree about
    # what half of the day it is.
    #
    # Late night gets its own set rather than borrowing evening's: the prompt
    # tells the model to drop the time-of-day framing after hours, and wishing
    # somebody a good evening at 2am is the exact tell it's trying to avoid.
    GREETING_KINDS = {
      "morning"    => :greeting_morning,
      "afternoon"  => :greeting_afternoon,
      "evening"    => :greeting_evening,
      "late night" => :greeting_late_night,
    }.freeze

    def greeting_kind(user)
      zone = ActiveSupport::TimeZone[user&.timezone.to_s] || Time.zone
      part = Buddy::Personality.part_of_day(Time.current.in_time_zone(zone))
      GREETING_KINDS.fetch(part, :greeting_morning)
    end

    # The weather half of the same idea as GREET_DIRECTIVE: the exact wording, so
    # Buddy::GPT::Turn can tell the seed really did carry a forecast before
    # deciding a briefing came back without one. Absent whenever `weather_block`
    # is empty, which is what keeps the repair off a late-in-the-day briefing
    # that was never given figures.
    WEATHER_DIRECTIVE = "THE HIGH AND THE LOW GO IN, in one short line.".freeze

    def weather_ordered?(seed_body)
      seed_body.to_s.include?(WEATHER_DIRECTIVE)
    end

    # The line, composed here rather than asked for.
    #
    # This is the third attempt and the first one that isn't a request. It went
    # in as "Give me the high and the low, in one short line", was rewritten to
    # THE HIGH AND THE LOW GO IN when that got dropped three briefings running,
    # and gained a pre-send readback naming it - and the three briefings after
    # that all carried the strongest wording yet and all went out with no
    # weather in them, eight running. The readback is being READ: its other two
    # checks held every time over those same three. It is this one line that
    # keeps losing, so it stops being a line the model has to remember to write.
    #
    # Same trade as with_greeting, and the same limit: this only fills a
    # silence. Whenever the model writes its own the model's is what ships,
    # because it can put the figures in a sentence that belongs to the rest of
    # the message and this can only put them on the end.
    NOTABLE_CLAUSES = {
      "rain"   => ->(pop) { "a #{pop}% chance of rain" },
      "storms" => ->(pop) { "storms around, #{pop}% chance" },
      "snow"   => ->(pop) { "snow, #{pop}% chance" },
      "windy"  => ->(_pop) { "wind worth knowing about" },
    }.freeze

    def weather_line(figures)
      figures = figures.to_h.symbolize_keys
      high    = figures[:high]
      low     = figures[:low]
      return nil if high.nil? || low.nil?

      clause = NOTABLE_CLAUSES[figures[:notable].to_s]&.call(figures[:rain].to_i)
      "High of #{high}°F today, low of #{low}°F#{", with #{clause}" if clause}."
    end

    # The week's flagged days, composed here for the same reason the line above
    # it is - and it is the same rule, losing the same way.
    #
    # 26 Aug: every seed carried "This week to flag: rain Thu, Fri, Sat & Sun.
    # Give a short heads-up for any day with rain / wind / snow", and Byte's
    # additionally carried a whole Alpine block reading 99%, 100%, 100%. All
    # THREE briefings went out with no mention of any of it. All three also
    # ended on the identical `weather_line` string, which is the tell: none of
    # the models wrote weather at all, the fallback filled today's figures, and
    # the week half had no fallback to fill it.
    #
    # Same trade as weather_line, again: this only fills a silence.
    def week_line(outlook)
      outlook = outlook.to_s.strip
      return nil if outlook.blank?

      "#{outlook[0].upcase}#{outlook[1..]} this week."
    end

    DAY_ABBREVS = %w[Mon Tue Wed Thu Fri Sat Sun].freeze

    # The days `week_outlook` flagged, as the abbreviations it wrote them in.
    def flagged_days(outlook)
      outlook.to_s.scan(/\b(#{DAY_ABBREVS.join('|')})\b/).flatten.uniq
    end

    # The words that make a day word a WEATHER mention rather than a date.
    WEATHER_WORDS_RX = /
      \b(?: rain|rainy|rains|shower|showers|wet|drizzle|downpour|
            storm|storms|stormy|thunder|lightning|
            snow|snowy|snowing|sleet|hail|
            wind|winds|windy|gust|gusts|gusty|breezy|
            sunny|forecast|weather|degrees )\b
    /xi

    # Did the briefing already say one of them?
    #
    # Generous inside a sentence, in the same direction weather_missing? is: a
    # flagged day named in ANY of the ways a person writes one suppresses the
    # repair, because a second heads-up under one the model wrote itself reads
    # worse than a rare miss. "tomorrow" is in the list because the prompt asks
    # for that word rather than the weekday name for the next day out, so a
    # correct briefing is one that never writes the abbreviation at all.
    #
    # But the day word has to be doing WEATHER work. Matched against the whole
    # body it wasn't: prod 4925 wrote "Nyjah Dinner on Monday at 6:30 PM" and
    # 4930 "Monday's got Nyjah Dinner at Texas Roadhouse too", Monday was a
    # flagged day, and both briefings went out with no forecast at all on a
    # Saturday carrying rain four days running. 4860 lost its line the same way
    # the morning before, on "a little art show tomorrow evening". An agenda
    # item on a rainy day is the ordinary case, not the rare one - the days
    # worth flagging and the days with plans are drawn from the same week.
    #
    # So the day word and a weather word have to be in the same sentence. The
    # cost is the mirror of the old one: a heads-up phrased around a word not on
    # the list ("Monday looks grim") earns a second line. That trade goes this
    # way because a duplicate is visible and a silence isn't.
    def week_said?(body, days, today: Date.current)
      return true if body.blank? || days.empty?

      words = day_words(days, today)
      sentences(body).any? { |sentence|
        sentence.match?(WEATHER_WORDS_RX) &&
          words.any? { |word| sentence.match?(/\b#{Regexp.escape(word)}\b/i) }
      }
    end

    # Sentences, and also lines: a briefing is half prose and half bullets, and
    # a bullet ending without punctuation is one sentence's worth of claim.
    def sentences(body)
      body.to_s.split(/\n+|(?<=[.!?])\s+/).map(&:strip).compact_blank
    end

    def day_words(days, today)
      days.flat_map { |abbrev|
        wday  = (DAY_ABBREVS.index(abbrev).to_i + 1) % 7
        names = [abbrev, Date::DAYNAMES[wday]]
        names << "tomorrow" if today.tomorrow.wday == wday
        names << "weekend" if [0, 6].include?(wday)
        names
      }.uniq
    end

    # Today's Alpine rain hours, composed here for the third time this rule has
    # needed composing.
    #
    # `weather_line` covers today's figures and `week_line` covers the week's
    # day names; the HOURS were the one piece of the weather rule with nothing
    # behind them, and they are the piece the seed asks for most directly -
    # "Rain windows today (give these times)". Dropped by all three briefings
    # on 27 Aug, and dropped again on 28 Aug by the briefing that got both of
    # the other two fallbacks right, which is what says it isn't a phrasing
    # problem.
    #
    # Same trade as the two above: this only fills a silence.
    def rain_hours_line(windows)
      windows = Array(windows).compact_blank
      return nil if windows.empty?

      "Rain in Alpine #{windows.to_sentence}."
    end

    # The start of a window as `PlungeAdvisor.format_window` writes one:
    # "8pm-9pm", "11pm-12am", "6pm-8pm".
    RAIN_WINDOW_RX = /\A(?<hour>\d{1,2})(?::\d{2})?(?<mer>am|pm)/i

    # Did the briefing already give one of the hours?
    #
    # Generous in the same direction `week_said?` is: an hour named in any of
    # the ways a person writes a clock time suppresses the repair, because a
    # second set of hours under ones the model wrote itself reads worse than a
    # rare miss. Only the START of each window is looked for - "rain from 6
    # tonight" is the sentence the rule wanted and it never names the end.
    def rain_hours_said?(body, windows)
      starts = Array(windows).filter_map { |w| RAIN_WINDOW_RX.match(w.to_s) }
      return true if body.blank? || starts.empty?

      starts.any? { |m|
        mer = m[:mer].downcase.chars.join("\\.?")
        body.match?(/(?<!\d)#{m[:hour]}\s*(?::\d{2})?\s*#{mer}\.?/i)
      }
    end

    # The departure time, composed here for the same reason the weather line is.
    #
    # `leave_by` arrives already worked out and the prompt is explicit about it
    # - "Both are figures; say the figures" - and it keeps losing to the shape
    # that names the CATEGORY instead. Prod 4529: "You've got Yoga first this
    # morning, with a pretty full drive time before it", sent at 8:25 to
    # somebody who had to walk out at 8:46, and neither figure in it. The travel
    # alert covered it eleven minutes later, which is the only reason nothing
    # broke; the briefing is the one that arrives while there is still time.
    #
    # Same trade as weather_line: this only fills a silence. When the model puts
    # the clock time in its own sentence, the model's is what ships.
    def leave_line(items)
      parts = Array(items).filter_map { |i|
        next if i[:leave_by].blank?

        drive = i[:drive_min].to_i
        "#{i[:title]}: leave by #{i[:leave_by]}#{", about #{drive} minutes' drive" if drive.positive?}"
      }
      return nil if parts.empty?

      "#{parts.join(". ")}."
    end
    # ---- the seed ----------------------------------------------------------
    #
    # Rocco, 2026-09-04: "We should re-write the entire prompt from scratch as
    # needed. Revisit every piece of it and make sure every piece earns its
    # mark."
    #
    # The old one ran to about two thousand words, and most of it was about
    # WHICH facts to use: where to look, what had already been filtered, what to
    # leave out, what not to claim about the things it had left out. All of that
    # is decided in Buddy::BriefingFacts now, in Ruby, where it's testable and
    # the same every day. What's left here is how to SOUND, and every line of it
    # is a rule about writing rather than about choosing.
    #
    # Two consequences worth stating, because they're what makes the rest short:
    #
    # - Nothing has to be looked up, so the briefing turn is offered no
    #   `get_context` at all (Buddy::GPT::Turn#tools). A model that can fetch
    #   twenty sections will read some of them out, whatever the prompt above
    #   them says.
    # - Rules are only in front of the model when the day has their subject in
    #   it. A paragraph about partners' calendars on a day with no partner item
    #   teaches it to go looking for one.
    #
    # Written POSITIVELY. "notes to write from, not lines to read out" was the
    # last anti-example standing and Rocco caught it: a rule phrased as the
    # mistake still hands over the mistake. Say the thing to do.

    # Rules whose subject can be absent from a day.
    WRITING_RULES = {
      travel:    "A leave-by is a clock time to walk out of the door, with the drive and the get-there-early buffer already taken off. Say it in the same sentence that names the thing - it's the part they can act on without doing the arithmetic.",
      # No sample sentence here, and there must not be one. The names in this
      # house are real, and every illustration ever written into this prompt has
      # come back out of it on a day it didn't fit. The SHAPE is the rule: name
      # first, then what they have, then when.
      partner:   "A line whose title starts with a name is that person's. Say it as theirs, in that order - who, what, when - so it lands as news about somebody they care about. One clause is plenty, and their own day is what the message is about.",
      all_day:   "Something marked all day is simply ON today. Name it and say today; the clock has nothing to add to a date.",
      cancelled: "A cancelled thing is one of the most useful lines in a briefing: a normal thing NOT happening is a real heads-up. Say it plainly.",
      jobs:      "Jobs listed under one name are one job, and the job is what the DAY is: several bin chores make it trash day, so say \"it's trash day\".",
      hot:       "A job with a multiplier on it is worth well above the usual today, which is worth some enthusiasm.",
      # Carries WEATHER_DIRECTIVE verbatim, and has to: Buddy::GPT::Turn decides
      # whether the briefing was GIVEN a forecast by looking for that exact
      # string in the seed, and reads the figures back off the reply on the
      # strength of it. Reword it without the constant and the repair silently
      # stops firing - which is how eight briefings in a row went out with no
      # weather in them.
      weather:   "#{WEATHER_DIRECTIVE} Anything above an ordinary day goes in with its odds; an ordinary sunny day is the baseline and the figures already cover it.",
      week_sky:  "Any day this week worth a heads-up gets a short one.",
      alpine:    "Alpine only ever comes up when the canyon is wet, so it's news by the time you're reading it. Give the hours wherever there are hours and the day on its own where there aren't. A plunge window is floated once and lightly, as something the day has room for.",
      waiting:   "Somebody in the house asked them something and it's still sitting there. Say who asked and what, so they can answer it.",
      week:      "The week gets at most one line, and only for something close enough or remarkable enough to earn it.",
      stash:     "Occasionally, and not most days, float one of the things on their mind. Light, one at a time, easy to wave off.",
    }.freeze

    def applicable_rules(facts)
      rules = []
      rules << :travel    if facts[:today].any? { |i| i[:leave_by].present? }
      rules << :partner   if facts[:today].any? { |i| i[:mine] == false }
      rules << :all_day   if facts[:today].any? { |i| i[:all_day] }
      rules << :cancelled if (facts[:today] + facts[:week]).any? { |i| i[:cancelled] }
      rules << :jobs      if facts[:jobs].any?
      rules << :hot       if facts[:jobs].any? { |j| j[:hot].present? }
      # On the HIGH, not on the block. Past mid-afternoon the figures are dropped
      # and only the week's outlook is left, and a rule asking for a high there
      # would put one back onto the briefing that decided it no longer mattered.
      rules << :weather   if facts.dig(:weather, :high).present?
      rules << :week_sky  if facts.dig(:weather, :week).present?
      rules << :alpine    if facts[:alpine].present? && facts[:alpine].values.flatten.compact_blank.any?
      rules << :week      if facts[:week].any?
      rules << :waiting   if Array(facts[:waiting]).any?
      rules << :stash     if facts[:stash].any?
      rules.map { |key| "- #{WRITING_RULES.fetch(key)}" }.join("\n")
    end

    def seed(user=nil, conversation=nil, facts: nil)
      conversation ||= (Buddy::CompanionRelay.conversation_for(user) if user)
      facts ||= Buddy::BriefingFacts.build(user, conversation)
      day     = Buddy::BriefingFacts.block(facts)
      name    = facts[:name].presence || "them"

      prompt = <<~PROMPT.strip
        You're writing #{name}'s Today, and what you write IS the message. It goes to them exactly as you write it, and nothing follows it.

        #{GREET_DIRECTIVE} It is the first thing in the message, before any news, and it holds even if you were talking a second ago and even if this is the second in a row - a Today opens with a hello the way a letter opens with a name. Take the half of the day from `Part of day` at the top of your prompt rather than from the shape of this request; these get asked for at all hours. The words are yours, different every time, and it has to land warm and lifted - on a `!`, a stretched vowel, or real warmth. Greet them by name, or with a plain hello.

        #{day.presence || "Nothing came back for today, so say so warmly, briefly, and stop."}

        Everything above is their day, already gathered and narrowed for you. It is the whole of it, so there's nothing to look up and nothing to work out - reframe it in your own words and pass it on.

        HOW TO SAY IT
        - All of it reaches them. Trim the words around a thing and keep the thing: a quiet day is two lines because the day is quiet, and a full one runs as long as the day does.
        - Only what's above. If it isn't there, it isn't happening today.
        - Call each thing by its name. Whose birthday, which meeting, who they're collecting - the name is the part they couldn't have guessed, and a category in its place sends them to the app to find out what you meant. Work in the place when the place is the point, and a time when it changes what they'd do.
        - Round odd clock times. Say "tomorrow" for the next day, and a weekday name from two days out.
        #{applicable_rules(facts)}

        #{TONE}
      PROMPT
      prompt.gsub(/\n{3,}/, "\n\n")
    end

    # Deliver a Today briefing as a hidden Buddy turn into `conversation`. Used
    # by the scheduled broadcast (the tap path goes through
    # QuickActionsController#dispatch_trigger for its action chip).
    #
    # Returns nil while Buddy is asleep, and only then. The guard used to sit in
    # Buddy::TodayScheduler, which was fine while that was the only way here — it
    # isn't any more, the schedule is a reminder now, and Buddy::ReminderFirer
    # has never checked it. Whether Buddy is awake enough to speak unprompted is
    # a property of the BRIEFING, not of whichever thing decided it was time.
    #
    # A hand-run is exempt: someone asking for one at 2am has already answered
    # the question the guard exists to ask.
    def deliver!(user, conversation, scheduled: true)
      return nil if scheduled && defined?(Buddy::SleepGuard) && Buddy::SleepGuard.sleeping?(user)

      facts = Buddy::BriefingFacts.build(user, conversation)
      msg   = conversation.byte_messages.create!(
        user:      user,
        direction: :outbound,
        state:     :pending,
        body:      seed(user, conversation, facts: facts),
        metadata:  {
          "kind"         => "buddy_trigger",
          "hidden"       => true,
          "source"       => scheduled ? "today_scheduled" : "quick_action",
          "buddy_action" => "today",
          # What the seed handed over, so a pre-send repair can check the reply
          # against exactly that. It used to read whatever the model happened to
          # fetch with `get_context`, which a briefing turn is no longer offered
          # at all - see Buddy::GPT::Turn#tools.
          "briefing"     => facts.as_json,
        },
      )
      MonitorChannel.broadcast_to(user, { id: :byte, channel: :byte, data: { kind: :message, message: msg.as_wire } })
      Buddy::ExpressionState.thinking!(conversation)
      BuddyDeliverWorker.perform_async(msg.id)
      msg
    end
  end
end
