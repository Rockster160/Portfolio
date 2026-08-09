module Buddy
  # The "Today" briefing seed + delivery. Fired two ways: by tapping the hero
  # "Today" chip, and by the scheduled broadcast (Buddy::TodayScheduler). Rails
  # owns the prompt text; the Mac just runs it.
  #
  # The SCHEDULE is a morning thing. The briefing is not — the chip is there all
  # day and gets tapped at all hours, so nothing in the seed may assume which
  # part of the day it's being read in. Anything that needs the hour reads it
  # off the clock (Buddy::Day) or off `Part of day` at the top of the prompt.
  module TodayBriefing
    module_function

    TONE = <<~TONE.strip.freeze
      LAST AND MOST IMPORTANT: this is still YOU talking, not a status readout.

      Everything above is about WHAT to say. This is about how it should sound. A briefing that reads like a dashboard summary is a failed briefing, even when every fact in it is right. You're a friend catching me up on my day, and you're glad to be the one doing it - so open like a person, use natural phrasing over clinical phrasing, and where something actually earns a reaction, give it one ("ooh, Andrew's birthday", "rain again, sorry", "nice, your afternoon's wide open"). A little real excitement about a good day is exactly right - that's the thing that tells me a friend read this and not a script. Keep it in your register though: glad and warm more often than bouncy, and every bit of it about something specific, never volume for its own sake.

      The one thing to trim is the reflex COMMENT - the aside stapled to the END of a line to round it off because the sentence felt like it wanted one. That is padding, and it is NOT the same as warmth. The trailing `, which is ...` clause is the usual shape, and so is a wry `Which, ...` fragment starting the next sentence:
      - "You've got some breathing room today." → right. Stop there.
      - "You've got some breathing room today, which is rare." → one clause too many.
      - "You've got some breathing room today. Which, honestly, is a first." → same thing wearing a full stop.

      (Those are shapes to avoid, not phrases to borrow. A memorable line in a don't-do example is still a line you read, and it has a way of turning up in the reply.)

      So keep the reaction, cut the commentary: warmth belongs at the FRONT of a line as a genuine reaction to something specific, not on the end as a wry observation. A joke that's actually good is worth sending; a joke that's only there because the line felt bare is the one to drop. If you're torn between flatter and warmer, go warmer - this should sound like someone who likes me, not someone filing a report.

      That rule is about the PADDING, not about where it sits. Moving the same empty flourish into the middle of the sentence doesn't retire it, it just hides it - and that is exactly what keeps happening: "sitting there all day like a birthday-shaped background process", "the fun little gremlin of the bunch", "a pretty chunky day on deck, but it's not a sneaky one", "hanging out for late evening". Every one of those is a comparison invented for the rhythm of the line, carrying no fact I didn't already have. The test is subtraction: cut the clause, and if the sentence still tells me everything it told me before, the clause was decoration. One genuinely funny observation in a message is yours to keep. A metaphor attached to each item in turn is a tic, and it is the single loudest way this stops sounding like you.

      Do not narrate the SHAPE of the message. "On the chore side...", "On the calendar...", "The big thing in the morning is..." are section headers with the formatting filed off - the same report, read aloud. A friend doesn't announce which part of the day they're about to cover, they just say the thing. Two briefings in a row opening their second sentence with "On the chore(s) side" is the tell that this is being assembled from a template instead of said.

      Keep it short - three to five lines - but short and warm, not short and clipped. Break it into short paragraphs with a blank line between distinct beats (a greeting, then what's ahead, then any week heads-up) so it renders clean and skimmable - never one smushed block. Enthusiasm and clean breaks are not at odds; you get both. Prose with shape and a pulse, not a field report.

      Still avoid: em dashes (commas or short sentences instead) and bullet-listing what I already did.

      Round odd clock times rather than reading them off: "7:54 AM" and "8:19" are what a machine says, "just before 8" is what you say. A time somebody actually scheduled on the hour or half hour ("3:00 PM" → "3") can stay as it is.

      An emoji, if you use one, has to be ABOUT something in the message. Warmth you actually feel toward me, a reaction to a specific thing. A 💙 parked on the end of a rundown of my chores is punctuation with a colour on it - it would have fit any other briefing equally well, and that's exactly what makes it noise. If it could move to a different message unchanged, it isn't doing anything.
    TONE

    # Comfort bands mirror the dashboard weather cell's colour scale. Woven into
    # the seed so the briefing frames weather the way we read it at a glance.
    # Time-aware: past ~4pm the day's high/comfort read is no longer actionable,
    # so we drop TODAY's weather and keep only the week outlook (upcoming days
    # still matter). Empty when there's nothing worth saying.
    def weather_block(user=nil)
      late = late_in_day?(user)
      week = WeatherService.week_outlook
      summary = WeatherService.summary unless late

      return "" if summary.blank? && week.blank?

      lines = ["", "WEATHER (weave it in naturally, don't recite a forecast):"]
      if summary.present?
        lines << "Today: #{summary}"
        lines += [
          "Comfort read on today's high:",
          "- ~62-75°F is the comfortable sweet spot - no need to fuss.",
          "- upper 70s is warm; mid-80s and up is hot - flag it, suggest light layers / water.",
          "- 50s is cool, 40s and below is cold; freezing or under, say to grab a coat.",
          "- real rain chance today? mention an umbrella.",
          "Skip the today-comfort line if it's unremarkable.",
        ]
      end
      lines << "This week to flag: #{week}. Give a short heads-up for any day with rain / wind / snow." if week.present?
      lines.join("\n")
    end

    # The briefing is chore-led for most people: what's still pending IS the
    # answer to "what's on today". For someone without chores that guidance is
    # worse than useless — it points the model at sections that aren't in their
    # context at all, so it either invents something or spends a paragraph
    # explaining an absence. The bullets come out entirely rather than being
    # softened, which also gets the prompt space back.
    def chores?(user)
      user.present? && Buddy::Features.enabled?(user, :chores)
    end

    # `chores_due_today` is the only chore section this turn can reach at all —
    # Buddy::GPT::ContextTool withholds the rest of them for a briefing (see
    # BRIEFING_WITHHELD). So this stopped needing to argue anyone out of the
    # full roster and only has to say what to do with the short list.
    #
    # Every earlier version of these bullets fought that battle in prose and
    # lost: a hard "THREE NAMES, TOTAL", an explicit "a daily is never one of
    # your three", a re-sorted bucket. Aug 7 named six, Aug 8 named six. Wording
    # does not beat a list that is sitting right there.
    def chores_lead_lines(user)
      return "" unless chores?(user)

      [
        "",
        "- `chores_due_today` is due today and isn't a daily habit - the stuff I'd forget on my own. It is the ONLY place chores come from, and it's the whole chore section of your context: there is no fuller list to fall back on, by design.",
        "- Name at most three of them, and only where the name has a REASON behind it: it's the one I'd start with, it's a big `hot` multiplier, it's an odd one-off. A run of names with no reason attached is a worse version of a screen I can open myself, and getting one every day is how a briefing stops being read.",
        "- Fewer than three is normal. It's a ceiling, never a quota.",
        "- If it's EMPTY, say nothing about chores at all and go to the calendar. Not \"nothing much on the chore front\", not a count, not the dailies - chores simply don't come up that day. A short briefing is not a failed one.",
        "- BATCH related items: several chores that are obviously one errand or one theme go out ONCE as the theme, not one by one. A word shared across their names is the giveaway - three chores that all start with the dog's name are \"the dog's round\", the bin ones are \"it's trash day\", all the plant watering is \"watering day\".",
        "- Never tell me I DID something. You can't see completions on this turn at all, and a shared chore counts the moment ANYONE in the house does it, so \"you knocked out X\" is a guess that's wrong often enough to matter.",
        "- A chore that isn't in that list does not exist for this message. Don't reach back for one you saw earlier in the thread, and don't write \"Still pending:\" followed by anything - that sentence is the failure mode however tidy it looks.",
      ].join("\n")
    end

    # A hot pick is worth naming only when it's unusual. Two-thirds of them are
    # a routine 2x, and "this one's flagged" about an ordinary 2x spends one of
    # the three names on nothing.
    def chores_hot_line(user)
      return "" unless chores?(user)

      "\n- A `hot` multiplier on one of them (\"2x\", \"5x\") means extra pebbles today. " \
        "A big one is genuinely worth a mention and a bit of enthusiasm (\"the litter box is a 5x today\"); " \
        "a plain 2x is ordinary and isn't news."
    end

    # After ~4pm local the day's weather isn't actionable anymore.
    def late_in_day?(user)
      return false if user.nil?

      hour = Buddy::Day.now(user).hour
      hour >= 16 || hour < Buddy::Day::ROLLOVER_HOUR
    end

    # Alpine plunge / notable-weather block. Only speaks up for rain/snow or
    # heavy dark clouds, and only when we have a user to localize + check the
    # agenda against. Empty otherwise (including off-prod).
    def plunge_block(user)
      return "" if user.nil?

      Buddy::PlungeAdvisor.briefing_block(user)
    rescue StandardError => e
      Rails.logger.warn("[Buddy::TodayBriefing] plunge block failed: #{e.class}: #{e.message}")
      ""
    end

    def seed(user=nil)
      prompt = <<~PROMPT.strip
        What's on for TODAY, forward-looking. This is a briefing about the day ahead, NOT a recap of yesterday or a review of what's already done.

        OPEN with a warm greeting when it fits. Take the half of the day from `Part of day` at the very top of your prompt - not the shape of this request, and not what a briefing usually sounds like (a briefing is not a morning thing; I ask for these at all hours). Match that part of day, but the WORDS are yours: vary the opener and make it interesting, never falling back to the same greeting every time.

        **Greeting me with the wrong part of the day is one of the most obviously broken things you can do.** Keep the half of the day it names; phrase it however you like, clipped or full.

        Lean into the greeting when it lands: the first check of the day, or when we haven't talked in a while. Skip it when we just talked a moment ago - don't greet twice in one thread.

        **Land the greeting warm and lifted, not on a flat period.** A hello that stops on a period reads deadpan, and the line after it inherits that flatness for the rest of the briefing. Give it a lift - a "!", a stretched vowel, real warmth - so it sounds happy to see me. "Hey hey, Rocco. Morning's got some real shape to it." is the flat version of exactly the right words; "Hey hey, Rocco!" is the same greeting doing its job.

        Never address me as "you" like a pet name - no "Morning, you", "Hey, you", "Well, hello you". That lands too intimate. Use my name, a plain greeting, or just dive in.
        #{weather_block(user)}#{plunge_block(user)}

        FORWARD-LOOKING ONLY. Only surface what's STILL AHEAD from `now_local`. Anything already over is not news:
        - Agenda items flagged `passed: true` are DONE for the day - never recite or recap them.
        - If it's evening or later and the day is essentially behind them (most items passed, little pending), DON'T force a full rundown. A day that's over doesn't need a briefing - give whatever is actually left tonight (if anything) and a quick nod to tomorrow, then stop. Short is correct here.

        LEAD WITH what still needs to happen today.
        #{chores_lead_lines(user)}
        - `today_agenda` - today's events / meetings with times. But see UNUSUAL-ONLY below: don't recite the daily-recurring stuff.
        - Agenda items tagged `mine: false` (with an `owner`, e.g. Chelsea) are on a partner's PERSONAL calendar shared with me - awareness only. They are NOT my tasks. Don't list them as mine; usually don't mention them at all. Only bring one up if it actually affects me (a conflict, a hand-off, something I'm part of), and attribute it ("Chelsea's got a thing at 3").#{chores_hot_line(user)}

        NAME THE THING, never just its category. Every item in context carries its real name, and the name is usually the entire reason it's worth mentioning. "Tomorrow's got the birthday" tells me nothing I can act on when the item is called `Monica Murton's Birthday` - it's WHOSE birthday that makes it matter, and the answer was right there. Same shape: "a meeting" for `Tech Stand-Up`, "an appointment" for `TMS`, "the thing Friday". If it earns a mention it earns its name.

        WHEN referring to a day: say "tomorrow" for the next day, not the weekday name. Weekday names only for two-plus days out.

        WEIGHT BY HOW ROUTINE IT IS (the `cadence` tag):
        - `cadence` of "daily" / "every weekday" = something I know cold. Don't recite it as news. A quick gloss is fine ("usual morning stuff, then...") but never a line-by-line of my standing schedule.
        - Less-frequent cadences ("weekly", "monthly", "yearly", "every 6 days") I may NOT have top of mind - a light touch helps ("your monthly 1:1 with Eric is this afternoon"). Touch on it, don't dive into details.
        - No `cadence` at all = a one-off (vet appt, dinner). Always worth surfacing.
        - DO call out a routine that's NOT happening: a `cancelled` item, especially a recurring one, is a real heads-up ("no standup tomorrow"). A normal thing missing beats a normal thing present.
        - `drive_min` on a soon item is a NUMBER OF MINUTES, and the number is the entire reason to bring it up. Say it: "about 20 minutes out, so leave by 7:40". Never mention that a drive exists without saying how long it is - "Ketamine at 8, with a drive time" tells me something I already know and withholds the one thing I asked for. If you're not going to give the minutes, don't raise the drive at all. Only worth raising when it's close enough to act on.

        REST OF THE WEEK (`upcoming_agenda`, tomorrow onward):
        - Weight by proximity - the closer, the more worth mentioning. Tomorrow's oddity matters more than something 6 days out; only a genuinely notable thing a week out earns a mention.
        - Same cadence weighting: gloss/skip the daily-and-weekday repeats, lightly flag the less-common recurrences and one-offs, call out cancelled routines. On a weekend, a unique Monday thing is fair game ("heads up, dentist Monday morning").
        - At most a line. If nothing worth noting is coming, say nothing about the week.

        SECONDARY (mention only if clearly relevant):
        - `stashed_ideas` - OCCASIONALLY (not most days) float ONE idea I brain-dumped, if it fits the moment. Light, one at a time, easy to wave off. Skip it entirely most of the time.

        DO NOT USE:
        - `recent_events` from before today started. Those are yesterday. This ask is about today, not a diary of the last 24 hours.
        - "Yesterday you..." framing at all. Yesterday is done. Today is what I'm asking about.
        - Motivational spin like "you crushed it yesterday, keep it up today". That's a review, not a briefing.

        HOW TO ANSWER:
        - Lead with pending / unusual-upcoming. Be specific about the few things you do name - vague gestures are the opposite failure and just as bad.
        - Prose, in short paragraphs. This is you talking, so it reads as sentences about my day, not as fields with values after them.
        - If the day looks empty, keep it short and warm - a "not much on deck today, what are you thinking?" not a recap of yesterday.

        HARD NO:
        - Never recap yesterday.
        - Never invent chores/events not in context.
        - No filler like "quiet day", "not a bad thing", "in the bag".
        - No "based on what I have" / "your context shows" / any scaffolding-talk.

        Aim for 3-5 short lines - easy to take in at a glance, but still sounding like you.

        #{TONE}
      PROMPT
      # Weather, the plunge advisory and every chore line collapse to "" for
      # someone who doesn't have them, leaving runs of blank lines behind.
      prompt.gsub(/\n{3,}/, "\n\n")
    end

    # Deliver a Today briefing as a hidden Buddy turn into `conversation`. Used
    # by the scheduled broadcast (the tap path goes through
    # QuickActionsController#dispatch_trigger for its action chip).
    def deliver!(user, conversation, scheduled: true)
      msg = conversation.byte_messages.create!(
        user:      user,
        direction: :outbound,
        state:     :pending,
        body:      seed(user),
        metadata:  {
          "kind"         => "buddy_trigger",
          "hidden"       => true,
          "source"       => scheduled ? "today_scheduled" : "quick_action",
          "buddy_action" => "today",
        },
      )
      MonitorChannel.broadcast_to(user, { id: :byte, channel: :byte, data: { kind: :message, message: msg.as_wire } })
      Buddy::ExpressionState.thinking!(conversation)
      BuddyDeliverWorker.perform_async(msg.id)
      msg
    end
  end
end
