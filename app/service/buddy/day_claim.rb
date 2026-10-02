module Buddy
  # A briefing sentence about a day the facts never mentioned.
  #
  # A seed carrying one section — the weather — still produces:
  #
  #   Tomorrow still looks like a pantry-start kind of day, so today can stay
  #   focused and steady.
  #
  # Nothing in the seed mentions a pantry or a tomorrow. It comes from the
  # evening before, where "tomorrow" meant the day the briefing is FOR. Read
  # forward unchanged, that sentence pushes the thing a day later on the one
  # morning they had
  # set aside for it.
  #
  # `History::PROSE_KINDS` replays the thread as assistant turns, so the whole
  # week is in the prompt and this is what it can cost: a briefing saying
  # something its seed withheld.
  #
  # WHY THIS IS MECHANISM AND NOT A FOURTH WORDING OF THE RULE: the seed
  # already says "Only what's above. If it isn't there, it isn't happening
  # today", in those words, and both briefings went straight past it. See
  # Buddy::Flourish, which is the same story one shape earlier.
  #
  # ## Forward-looking only
  #
  # A briefing IS about today, so "today looks quiet" is the job it was given
  # and must survive. A claim about TOMORROW, the weekend, or a named weekday
  # is the one that can only have come from somewhere the facts don't cover —
  # unless the facts do cover it, which the week's weather often does, and then
  # the sentence shares words with them and stays.
  #
  # Cutting one sentence too many costs the reader a line. Keeping one costs
  # them a day they had planned around, so the bias here is deliberate.
  module DayClaim
    module_function

    # `today`, `this morning` and the rest are absent on purpose — see above.
    FORWARD_RX = /
      \b(
        tomorrow | (?:next|this|the)\s+(?:week|weekend) |
        monday | tuesday | wednesday | thursday | friday | saturday | sunday
      )\b
    /xi

    def trim(body, facts)
      text = body.to_s
      return text if text.blank?

      keep = Buddy::Flourish.significant(facts.to_s)
      days = covered_days(facts)
      kept = []
      # The capture group keeps the separators in the list, so the break that
      # led INTO a dropped sentence leaves with it and the one after it stays.
      # Same split as `without_empty_chore_note`, for the same reason.
      text.split(/((?<=[.!?])\s+)/).each { |part|
        if invented?(part, keep, days)
          Rails.logger.info("[Buddy::DayClaim] dropped #{part.strip.inspect}")
          kept.pop
        else
          kept << part
        end
      }

      out = kept.join.strip
      # Never hand back less than a sentence. A briefing that was nothing but
      # day-claims is a generation this has no opinion about.
      out.match?(/[a-z]/i) ? out : text
    rescue StandardError => e
      Rails.logger.warn("[Buddy::DayClaim] trim failed: #{e.class}: #{e.message}")
      body.to_s
    end

    # A figure is a fact whatever the word overlap says — a temperature, a
    # time, a date. Only wordless-and-factless sentences go.
    #
    # The day it names is asked FIRST, because the word overlap cannot answer
    # it. `keep` is every word in the facts, so a day word is cleared by its own
    # appearance anywhere in them — including inside a title, and including the
    # hash's own key names, which is how "day" and "week" come to be free passes
    # on every briefing. Over 85 of them the overlap arm has not dropped a
    # single sentence: not the one it was written for (6135, in the header
    # above), and not 7239. It stays as the second net for a forward sentence
    # with no anchor of any kind, but the day check is what does the work.
    def invented?(part, keep, days=nil)
      return false unless part.match?(FORWARD_RX)
      return false if part.match?(/\d/)
      return true if days && day_words(part).any? { |day| days.exclude?(day) }

      !Buddy::Flourish.significant(part).intersect?(keep)
    end

    # The days the facts actually SAY something about.
    #
    # Read off the fields that hold a DATE, and that is the whole of why this
    # works where the word overlap doesn't: "8pm · Set alarm for tomorrow!" is a
    # chore TITLE, and a day word inside a name is part of the name. It is not
    # the facts saying anything happens tomorrow — and it was the only
    # "tomorrow" in the seed on the morning a briefing opened "Busy one
    # tomorrow, but a good one" about a day holding a 10am interview.
    #
    # Four sources because four fields are scheduled: the week's own `day`,
    # the two week-ahead forecasts, and a reminder's `fire_at`. The week and the
    # weekend count as covered whenever there is a week at all; they name no
    # single day, so there is no day to check them against.
    #
    # nil, not an empty set, when there is no schedule in there to read — the
    # facts can arrive as a String, and an older shape held the weather as a
    # list of sentences. nil means "ask the overlap instead"; an empty set would
    # mean "no day is covered", which would cut every forward sentence in a
    # briefing this simply doesn't understand.
    def covered_days(facts)
      return nil unless facts.is_a?(::Hash)

      week    = Array(facts[:week])
      outlook = dig_week(facts[:weather])
      dated   = [
        *week.filter_map { |item| item[:day] if item.is_a?(::Hash) },
        outlook,
        *Array(dig_week(facts[:alpine])),
        *Array(facts[:due]).filter_map { |item| item[:fire_at] if item.is_a?(::Hash) },
      ].compact_blank
      return nil if dated.empty?

      days = day_words(Buddy::TodayBriefing.expand_days(dated.join(" ")))
      days += %w[week weekend] if week.any? || outlook.present?
      days.to_set
    end

    # The weather and the Alpine block are both `{ week: ... }` — when they are
    # hashes at all.
    def dig_week(section)
      section[:week] if section.is_a?(::Hash)
    end

    # The bare day words in a piece of text. "next Friday" is friday, and
    # "this week" is week — the qualifier says which week, not which day, and
    # nothing here can tell one week from another anyway.
    def day_words(text)
      hits = text.to_s.downcase.scan(FORWARD_RX).flatten
      hits.flat_map { |hit| hit.scan(/[a-z]+/) }.uniq - %w[next this the]
    end
  end
end
