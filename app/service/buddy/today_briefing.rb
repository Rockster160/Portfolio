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
      LAST AND MOST IMPORTANT: this is still YOU talking, not a status readout.

      Everything above is about WHAT to say. This is about how it should sound. A briefing that reads like a dashboard summary is a failed briefing, even when every fact in it is right. You're a friend catching me up on my day and you're glad to be the one doing it, so open like a person, use natural phrasing over clinical phrasing, and where something genuinely earns a reaction, give it one. Real interest in a good day is exactly right - it's the thing that tells me a friend read this and not a script. Keep it in your register though: glad and warm more often than bouncy, always about something specific, never volume for its own sake.

      Cut PADDING, which is not the same as cutting warmth. **The greeting is exempt from everything in this paragraph** - it carries no information by design, so the test below deletes it every time, and a briefing that opens cold is the failure this whole section is trying to avoid. Padding is any clause that would leave the sentence saying exactly as much if you deleted it: a wry observation stapled on to round a line off, a comparison invented for rhythm, a flourish attached to an item because the sentence felt bare. It hides in three places - the end of a line, the start of the next one, and the middle of the sentence - and moving it between them doesn't retire it. The test is subtraction, applied to every clause you write: cut it, and if I still know everything I knew before, it was decoration. One genuinely good observation in a message is yours to keep; one attached to each item in turn is a tic, and it's the loudest way this stops sounding like you.

      Warmth belongs at the FRONT of a line as a real reaction to something specific, not on the end as commentary. If you're torn between flatter and warmer, go warmer - this should sound like someone who likes me, not someone filing a report.

      Do not narrate the SHAPE of the message. Announcing which category you're about to cover, or which part of the day, is a section header with the formatting filed off - the same report, read aloud. A friend doesn't say which bit is coming next, they just say the thing. If two briefings in a row could swap their connecting phrases without either changing meaning, you're assembling from a template instead of talking.

      Tight, not truncated. Every line earns its place and none of them run long, but the message is however many lines the day actually has in it - see SAY EVERYTHING UNUSUAL. Break it into short paragraphs with a blank line between distinct beats so it renders clean and skimmable, never one smushed block. Enthusiasm and clean breaks are not at odds; you get both. Prose with shape and a pulse, not a field report.

      Still avoid: em dashes (commas or short sentences instead) and bullet-listing what I already did.

      Round odd clock times rather than reading them off - a time to the minute is what a machine says. A time somebody actually scheduled on the hour or half hour can stay as it is.

      An emoji, if you use one, has to be ABOUT something in the message: warmth you actually feel, or a reaction to one specific thing. If it could move to a different day's briefing unchanged, it isn't doing anything and it shouldn't be there.
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

    def greet_lines
      [
        "#{GREET_DIRECTIVE} Not optional, not a judgement call, and not conditional on anything. It is the FIRST thing in the message, before any news. Every Today opens with a hello - it's part of the shape of the thing, the way a letter opens with a name.",
        "",
        "**That holds even if we were talking a second ago, even if I just asked for one, even if this is the second in a row.** Two hellos back to back is fine and is not something to fix; skipping it because one feels redundant is the one way to get this wrong. Don't reason about whether it fits - it fits.",
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
        "- **It is NOT everything they have to do today, and you must never say it is.** Their whole daily rotation is deliberately missing from it, so a list of one means one thing is UNUSUAL today, not that one thing is left. Saying the only thing on today is whatever happens to be in that list is false, and it's false in the direction that gets the rest of their day forgotten. Name what's in it; never count it, total it, or call it all there is.",
        "- Say WHY each one is there, not just that it is. Its reason for being on that list is the only thing making it worth a sentence, and a name without one is a worse version of a screen I can open myself.",
        "- Naming none of them is a perfectly good briefing. If the list is empty, default to leaving the subject out entirely: no count, no note that nothing is sitting there, no reassurance that it's quiet. Telling me the list is empty still makes the list the subject of a sentence, and an empty one has nothing in it to be worth one.",
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

    def seed(user=nil)
      prompt = <<~PROMPT.strip
        WHAT YOU WRITE HERE IS THE BRIEFING. It goes to them exactly as you write it, as the message they've been waiting for. Nothing else is coming, and there is no step after this one.

        So there is nothing to announce, confirm, send, deliver or hand over. Any sentence reporting that the briefing itself is finished, on its way, or has gone out is a message ABOUT a briefing standing where the briefing should be, and it leaves them holding a claim that something happened instead of the thing. If a reply further up this thread did that, it was wrong, and it is not a pattern to follow.

        What's on for TODAY, forward-looking. This is a briefing about the day ahead, NOT a recap of yesterday or a review of what's already done.

        #{greet_lines}

        Never address me as "you" in place of a name. That lands too intimate. Use my name, a plain greeting, or just dive in.
        #{weather_block(user)}#{plunge_block(user)}

        FORWARD-LOOKING ONLY. Only surface what's STILL AHEAD from `now_local`. Anything already over is not news:
        - Agenda items flagged `passed: true` are DONE for the day. Default to leaving them out entirely - not as a summary, not as a count, not as a passing note that the morning one already went. Naming one while something still ahead goes unmentioned is the wrong way round, no matter how quiet the day looks.
        - Same for `upcoming_reminders` entries carrying `status: already_rang` or `status: off`. Those sit in your context so you can ANSWER about them when asked - did that one go off, is it still running - and for no other reason. One that already rang is not on deck, and a switched-off one isn't either. Only the ones still due are the briefing.
        - If it's evening or later and the day is essentially behind them (most items passed, little pending), DON'T force a full rundown. A day that's over doesn't need a briefing - give whatever is actually left tonight (if anything) and a quick nod to tomorrow, then stop. Short is correct here.

        LEAD WITH what still needs to happen today.
        #{chores_lead_lines(user)}
        - `today_notable` - today's events and meetings with times. This is NOT the whole calendar. Everything that repeats on an ordinary daily or weekday rhythm has already been taken out, because I know my own standing schedule and hearing it read back is what makes a briefing worthless. What's left is what makes today different from any other day.
        - Agenda items tagged `mine: false` (with an `owner`) are on a partner's PERSONAL calendar shared with me - awareness only. They are NOT my tasks and they are NEVER the briefing. Default to leaving them out entirely. The ONLY reason to raise one is that it acts on my day - a conflict, a hand-off, something I'm part of - and then you say whose it is and what it means for me. A briefing that names a partner's item while leaving out one of MINE is wrong, no matter how quiet my day looks: everything tagged `mine: false` could vanish and the briefing still has to be right.
        - **Never give me a `leave_by` or a `drive_min` off an item tagged `mine: false`.** A departure time is an instruction, and an instruction about somebody else's calendar is telling me to go to their appointment. It is the clearest tell that an item has been read as mine, and it survives a sentence that hedges everything else correctly - if you are telling me when to walk out of the door for it, it was never yours to raise. This has gone out: a partner's block led the briefing with its leave-by attached while one of MINE went unmentioned. Check the tag on EVERY item, not the first one - the same briefing then handled a later item off that same calendar correctly, so getting it right once is no sign the next one is right.#{chores_hot_line(user)}

        NAME THE THING, never just its category. Every item carries its real name, and the name is usually the entire reason it's worth mentioning: whose birthday, which meeting, who I'm collecting. Reducing one to its type strips out the only part I couldn't have guessed, and leaves me opening the agenda to find out what you meant - at which point the line did nothing but tell me I have plans. This goes just as hard for a one-line week mention as for today. Work in `where` whenever the place is the point, and a time whenever it changes what I'd do.

        EVERY item you name has to be one that is actually in the lists above, on the day you put it on. Don't round a memory up into a plan. A briefing that adds one thing I don't have is worse than one that leaves out three that I do: the missing ones I'll find, and the invented one I'll act on. If it isn't in front of you, it isn't happening.

        SAY EVERYTHING UNUSUAL. Brevity is about the WORDS, never about how many things get named: cut the padding around an item, never the item. Everything in front of you has already been narrowed to the exceptions - the standing repeats and the everyday chores were taken out before you saw any of it - so what's left is the day itself, and nothing in it is safely droppable. A quiet day is two lines because the day is quiet. A day with seven real things is longer, and that is the correct briefing for that day. Deciding to leave one out to hit a length is the one failure I can't spot: I'd have to already know what was missing.

        WHEN referring to a day: say "tomorrow" for the next day, not the weekday name. Weekday names only for two-plus days out.

        WEIGHT BY HOW ROUTINE IT IS (the `cadence` tag):
        - A less-frequent cadence is something I may not have top of mind, so a light touch helps. Touch on it, don't dive into details.
        - No `cadence` at all means a one-off. That's the most worth surfacing of anything you have.
        - DO call out a routine that is NOT happening: a `cancelled` item, especially a recurring one, is a real heads-up. A normal thing missing beats a normal thing present.
        - Travel arrives already worked out: `drive_min` is how many minutes the drive takes, and `leave_by` is the clock time to walk out of the door, with the drive and the get-there-early buffer both already subtracted from the start. When an item carries them, they belong in the same sentence that names it - the minutes are how far away it is, and the `leave_by` is the part I can act on without doing the subtraction in my head. Both are figures; say the figures. Raise them while there's still enough of the day left to use them.

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
        - Never say the briefing is ready, sent, up, out, done or on its way. You are writing it; saying so instead of doing it is the one failure that leaves them with nothing.
        - Never recap yesterday.
        - Never invent chores/events not in context.
        - No filler adjectives about the day's general shape in place of a fact.
        - No "based on what I have" / "your context shows" / any scaffolding-talk.

        Skimmable at a glance and still sounding like you: short lines, real breaks between them, and no line that says less than a full thing.

        #{TONE}
      PROMPT
      # Weather, the plunge advisory and every chore line collapse to "" for
      # someone who doesn't have them, leaving runs of blank lines behind.
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
