module Buddy
  # A briefing sentence about a day the facts never mentioned.
  #
  # Prod 6137, 15 Sep. Suki's seed carried one section — the weather — and the
  # briefing said:
  #
  #   Tomorrow still looks like a pantry-start kind of day, so today can stay
  #   focused and steady.
  #
  # Nothing in the seed mentions a pantry or a tomorrow. It came from the
  # evening before (prod 6118), where Eve said she believed TOMORROW would be
  # the day she could start on the pantry — and from where she was standing,
  # tomorrow was the Monday the briefing was for. Read forward unchanged, her
  # own sentence pushed the pantry start to Tuesday on the one morning she had
  # set aside for it.
  #
  # `History::PROSE_KINDS` replays the thread as assistant turns, so the whole
  # week is in the prompt and this is what it can cost. The second briefing
  # running to say something its seed withheld; 6099 on 13 Sep was the first.
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
      kept = []
      # The capture group keeps the separators in the list, so the break that
      # led INTO a dropped sentence leaves with it and the one after it stays.
      # Same split as `without_empty_chore_note`, for the same reason.
      text.split(/((?<=[.!?])\s+)/).each { |part|
        if invented?(part, keep)
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
    def invented?(part, keep)
      return false unless part.match?(FORWARD_RX)
      return false if part.match?(/\d/)

      !Buddy::Flourish.significant(part).intersect?(keep)
    end
  end
end
