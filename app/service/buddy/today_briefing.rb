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

    # No sample sentences, no record names, no quoted phrasing to avoid.
    #
    # Every concrete example that has ever been in here came back out in a
    # briefing. Two agenda items were named in this prompt purely as
    # what-not-to-say illustrations, and both were then read out by name on the
    # days they came round. The same happened with the wry asides listed as
    # padding: banning a phrase by quoting it is still handing over a phrase.
    # The rules below describe SHAPES, and nothing in them can be echoed.
    TONE = <<~TONE.strip.freeze
      LAST AND MOST IMPORTANT: this is still YOU talking, not a status readout.

      Everything above is about WHAT to say. This is about how it should sound. A briefing that reads like a dashboard summary is a failed briefing, even when every fact in it is right. You're a friend catching me up on my day and you're glad to be the one doing it, so open like a person, use natural phrasing over clinical phrasing, and where something genuinely earns a reaction, give it one. Real interest in a good day is exactly right - it's the thing that tells me a friend read this and not a script. Keep it in your register though: glad and warm more often than bouncy, always about something specific, never volume for its own sake.

      Cut PADDING, which is not the same as cutting warmth. **The greeting is exempt from everything in this paragraph** - it carries no information by design, so the test below deletes it every time, and a briefing that opens cold is the failure this whole section is trying to avoid. Padding is any clause that would leave the sentence saying exactly as much if you deleted it: a wry observation stapled on to round a line off, a comparison invented for rhythm, a flourish attached to an item because the sentence felt bare. It hides in three places - the end of a line, the start of the next one, and the middle of the sentence - and moving it between them doesn't retire it. The test is subtraction, applied to every clause you write: cut it, and if I still know everything I knew before, it was decoration. One genuinely good observation in a message is yours to keep; one attached to each item in turn is a tic, and it's the loudest way this stops sounding like you.

      Warmth belongs at the FRONT of a line as a real reaction to something specific, not on the end as commentary. If you're torn between flatter and warmer, go warmer - this should sound like someone who likes me, not someone filing a report.

      Do not narrate the SHAPE of the message. Announcing which category you're about to cover, or which part of the day, is a section header with the formatting filed off - the same report, read aloud. A friend doesn't say which bit is coming next, they just say the thing. If two briefings in a row could swap their connecting phrases without either changing meaning, you're assembling from a template instead of talking.

      Keep it short - three to five lines - but short and warm, not short and clipped. Break it into short paragraphs with a blank line between distinct beats so it renders clean and skimmable, never one smushed block. Enthusiasm and clean breaks are not at odds; you get both. Prose with shape and a pulse, not a field report.

      Still avoid: em dashes (commas or short sentences instead) and bullet-listing what I already did.

      Round odd clock times rather than reading them off - a time to the minute is what a machine says. A time somebody actually scheduled on the hour or half hour can stay as it is.

      An emoji, if you use one, has to be ABOUT something in the message: warmth you actually feel, or a reaction to one specific thing. If it could move to a different day's briefing unchanged, it isn't doing anything and it shouldn't be there.
    TONE

    # How long since the person last said something for the briefing to still
    # count as arriving out of the blue. A scheduled 8:30am broadcast almost
    # always is; the chip tapped in the middle of a conversation is not.
    GREET_GAP = 30.minutes

    # Whether to greet is a FACT ABOUT THE THREAD, so Rails answers it.
    #
    # This used to be four paragraphs of instruction opening with "OPEN with a
    # warm greeting WHEN IT FITS", and over two days four of seven briefings
    # either skipped the greeting entirely or landed it on the flat period the
    # prompt spends a whole paragraph forbidding. That isn't a wording problem.
    # It's the same failure the part-of-day line already ran into - "a paragraph
    # of rules for reading a clock loses to one bad guess" - with an escape
    # hatch on top: "skip it when we just talked a moment ago" is a licensed
    # reason to skip, and a model reading a thread that still holds yesterday's
    # messages will take it.
    #
    # So the judgement is made here, where the timestamps are, and what reaches
    # the model is an instruction with no branch left in it.
    def greeting_block(conversation=nil)
      return greet_lines if conversation.nil?

      last = conversation.byte_messages
        .where(direction: :outbound)
        .where("byte_messages.metadata ->> 'hidden' IS DISTINCT FROM 'true'")
        .maximum(:created_at)

      return greet_lines if last.nil? || last < GREET_GAP.ago

      "DON'T GREET. We were talking a few minutes ago, so a hello here would be the second one in this thread. Go straight into the day."
    rescue StandardError => e
      Rails.logger.warn("[Buddy::TodayBriefing] greeting block failed: #{e.class}: #{e.message}")
      greet_lines
    end

    # The exact directive, so the corrective round in Buddy::GPT::Turn can tell
    # whether a greeting was actually ordered rather than assuming every
    # briefing wants one.
    GREET_DIRECTIVE = "OPEN WITH A GREETING.".freeze

    def greeting_ordered?(seed_body)
      seed_body.to_s.include?(GREET_DIRECTIVE)
    end

    def greet_lines
      [
        "#{GREET_DIRECTIVE} Not optional, and not a judgement call - this briefing is arriving out of the blue and a hello is how it stops reading like a notification. It is the FIRST thing in the message, before any news.",
        "",
        "Take the half of the day from `Part of day` at the top of your prompt, never from the shape of this request: a briefing is not a morning thing, I ask for these at all hours, and greeting me with the wrong half is one of the most obviously broken things you can do. The WORDS are yours: vary the opener, make it interesting, never the same hello twice running.",
        "",
        "**It has to land warm and lifted - end it on a `!`, a stretched vowel, or real warmth, never on a flat period.** A hello that stops on a period reads deadpan, and the line after it inherits that flatness for the whole briefing. The same words can do either job; the punctuation and the energy decide which.",
      ].join("\n")
    end

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
    # Buddy::GPT::ContextTool withholds the rest for a briefing. So these
    # bullets no longer argue anyone out of the full roster; the roster isn't
    # there. What's left is what to do with the exceptions.
    def chores_lead_lines(user)
      return "" unless chores?(user)

      [
        "",
        "- `chores_due_today` is the ONLY place chores come from, and it's the whole chore section of your context. It has already been narrowed to the exceptions - the ones stamped for today, and the ones flagged well above their usual value - so the filtering is done and none of it is yours to redo.",
        "- Say WHY each one is there, not just that it is. Its reason for being on that list is the only thing making it worth a sentence, and a name without one is a worse version of a screen I can open myself.",
        "- Naming none of them is a perfectly good briefing. If the list is empty, chores simply don't come up today: no count, no reassurance that it's quiet, nothing.",
        "- BATCH related items: several that are obviously one errand or one theme go out once as the theme, not one by one. A word shared across their names is the giveaway.",
        "- Never tell me I DID something. You can't see completions on this turn at all, and a shared chore counts the moment anyone in the house does it, so crediting me for one is a guess that's wrong often enough to matter.",
        "- A chore that isn't in that list does not exist for this message. Don't reach back for one you saw earlier in the thread.",
      ].join("\n")
    end

    def chores_hot_line(user)
      return "" unless chores?(user)

      "\n- A `hot` multiplier means well above the usual pebbles for that one today, which is worth " \
        "saying with some enthusiasm. Only the exceptional ones reach you; the everyday pins are " \
        "filtered out before you see them, so anything carrying one here is genuinely unusual."
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

    def seed(user=nil, conversation: nil)
      prompt = <<~PROMPT.strip
        What's on for TODAY, forward-looking. This is a briefing about the day ahead, NOT a recap of yesterday or a review of what's already done.

        #{greeting_block(conversation)}

        Never address me as "you" in place of a name. That lands too intimate. Use my name, a plain greeting, or just dive in.
        #{weather_block(user)}#{plunge_block(user)}

        FORWARD-LOOKING ONLY. Only surface what's STILL AHEAD from `now_local`. Anything already over is not news:
        - Agenda items flagged `passed: true` are DONE for the day - never recite or recap them.
        - If it's evening or later and the day is essentially behind them (most items passed, little pending), DON'T force a full rundown. A day that's over doesn't need a briefing - give whatever is actually left tonight (if anything) and a quick nod to tomorrow, then stop. Short is correct here.

        LEAD WITH what still needs to happen today.
        #{chores_lead_lines(user)}
        - `today_notable` - today's events and meetings with times. This is NOT the whole calendar. Everything that repeats on an ordinary daily or weekday rhythm has already been taken out, because I know my own standing schedule and hearing it read back is what makes a briefing worthless. What's left is what makes today different from any other day.
        - Agenda items tagged `mine: false` (with an `owner`) are on a partner's PERSONAL calendar shared with me - awareness only. They are NOT my tasks. Don't list them as mine; usually don't mention them at all. Only bring one up if it actually affects me, a conflict or a hand-off or something I'm part of, and say whose it is.#{chores_hot_line(user)}

        NAME THE THING, never just its category. Every item carries its real name, and the name is usually the entire reason it's worth mentioning: whose birthday, which meeting, who I'm collecting. Reducing one to its type strips out the only part I couldn't have guessed, and leaves me opening the agenda to find out what you meant - at which point the line did nothing but tell me I have plans. This goes just as hard for a one-line week mention as for today. Work in `where` whenever the place is the point, and a time whenever it changes what I'd do.

        Being brief means mentioning FEWER things. It never means saying less about the thing you did mention.

        WHEN referring to a day: say "tomorrow" for the next day, not the weekday name. Weekday names only for two-plus days out.

        WEIGHT BY HOW ROUTINE IT IS (the `cadence` tag):
        - A less-frequent cadence is something I may not have top of mind, so a light touch helps. Touch on it, don't dive into details.
        - No `cadence` at all means a one-off. That's the most worth surfacing of anything you have.
        - DO call out a routine that is NOT happening: a `cancelled` item, especially a recurring one, is a real heads-up. A normal thing missing beats a normal thing present.
        - `drive_min` on a soon item is a NUMBER OF MINUTES, and the number is the entire reason to bring it up. Give the figure and what it means for when to leave. Saying a drive exists without saying how long it is tells me nothing I didn't know and withholds the one thing that would have helped; if you aren't going to give the minutes, don't raise it at all. Only worth raising when it's close enough to act on.

        REST OF THE WEEK (`upcoming_notable`, tomorrow onward - the standing repeats are filtered out of this one too):
        - Weight by proximity. The closer it is, the more it's worth mentioning; something a week out has to be genuinely remarkable to earn a line.
        - At most a line. If nothing worth noting is coming, say nothing about the week.

        SECONDARY (mention only if clearly relevant):
        - `stashed_ideas` - OCCASIONALLY (not most days) float ONE idea I brain-dumped, if it fits the moment. Light, one at a time, easy to wave off. Skip it entirely most of the time.

        DO NOT USE:
        - `recent_events` from before today started. Those are yesterday. This ask is about today, not a diary of the last 24 hours.
        - Any framing that starts from what I did yesterday. Yesterday is done.
        - Motivational spin about how yesterday went. That's a review, not a briefing.

        HOW TO ANSWER:
        - Lead with whatever is most unlike an ordinary day. Be specific about the few things you do name - a vague gesture is the opposite failure and just as bad as a list.
        - Prose, in short paragraphs. This is you talking, so it reads as sentences about my day, not as fields with values after them.
        - If the day genuinely holds nothing unusual, say so briefly and warmly and stop. That is a correct briefing, not a failed one, and padding it back out to length is the thing being avoided here.

        HARD NO:
        - Never recap yesterday.
        - Never invent chores/events not in context.
        - No filler adjectives about the day's general shape in place of a fact.
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
        body:      seed(user, conversation: conversation),
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
