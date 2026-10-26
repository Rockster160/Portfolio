module Buddy
  # Bold that has stopped meaning anything, thinned back until it does.
  #
  # The briefing prompt already forbids this in as many words - "what it must
  # not become is every name and every time in turn" - and the last five Byte
  # briefings out of six ignored it, getting steadily worse: 15 bold spans,
  # then 26, 24, 28, and 37 in 1,161 characters. At 37 it was every title,
  # every time, every place, both temperatures and both rain percentages, which
  # is a briefing with no emphasis at all wearing a lot of asterisks.
  #
  # So this is mechanism rather than a sixth wording of the rule, for the same
  # reason Buddy::Flourish is: each morning's briefing sits in the history the
  # next one is written against, so the pattern teaches itself faster than the
  # prompt can argue with it. The model is told nothing about this, which also
  # means it has nothing to route around.
  #
  # Scarcity is the whole of what emphasis is, so that is what gets measured -
  # spans against SENTENCES, not a number somebody picked. More bold runs than
  # sentences means every sentence has more than one, and at that point none of
  # them is standing out from the others.
  #
  # Measured against the real ones rather than guessed. The five that went this
  # way ran 15, 26, 24, 28 and 37 spans over 12, 13, 15, 13 and 8 sentences, so
  # every one of them is over the line; the briefings nobody complained about,
  # on the same mornings off the same seeds, carry NO bold at all. There is no
  # healthy middle in the sample, which is what makes a line this blunt safe to
  # draw.
  module Emphasis
    module_function

    # `**like this**`, non-greedy and within one line, so an unclosed pair
    # can't swallow the rest of the briefing. Single asterisks are left alone:
    # italics are not what went wrong and the prompt welcomes them. An italic
    # pair may sit inside the span - an event titled "Party *bring Whisper*" is
    # bolded whole, and without this its closing `**` paired with the next
    # span's opener.
    SPAN_RX = /\*\*(?=\S)((?:[^*\n]|\*[^*\n]+\*)+?)\*\*/

    # Below this, emphasis is scarce enough that none of it is taken off
    # wholesale. It also keeps a two-sentence briefing from losing every span
    # over three, where the ratio alone would. Figures still come off a short
    # one that is over the line - a time in bold beside every name is the same
    # overrun at any length.
    FLOOR = 8

    # A span carrying only a FIGURE - a time, a temperature, a percentage, a
    # bare number, a span of two of them. These are the ones the overrun is
    # made of, and digits in prose are already distinct enough to find without
    # help. Dropped first, because a name is the thing a glance is looking for.
    FIGURE_RX = %r{
      \A
      [^a-z]*
      \d[\d\s:.,/°%-]*
      (?:[ap]\.?m\.?|am|pm|°?[cf]|%|min(?:ute)?s?|hrs?|hours?)?
      (?:\s*(?:-|to|–|—)\s*\d[\d\s:.,/°%-]*
         (?:[ap]\.?m\.?|am|pm|°?[cf]|%|min(?:ute)?s?|hrs?|hours?)?)?
      [^a-z]*
      \z
    }xi

    # Sentences, and also lines: a briefing is half prose and half bullets, and
    # a bullet is one sentence's worth of claim. Same split
    # Buddy::TodayBriefing uses, for the same reason.
    def sentences(body)
      body.to_s.split(/\n+|(?<=[.!?])\s+/).map(&:strip).compact_blank
    end

    def spans(body)
      body.to_s.scan(SPAN_RX).flatten
    end

    def thin(body)
      text  = body.to_s
      found = spans(text)
      return body if found.length <= sentences(text).length

      # Figures first. If that is enough to bring it back under, the names keep
      # their emphasis and the briefing reads the way the rule always wanted.
      text  = text.gsub(SPAN_RX) { |span| figure?(::Regexp.last_match(1)) ? ::Regexp.last_match(1) : span }
      return text if found.length < FLOOR

      found = spans(text)
      return text if found.length <= sentences(text).length

      # Still every sentence over. Which four of thirty-seven were the ones
      # that mattered is not answerable from here, and picking by position
      # would be inventing an answer - so all of it goes. A briefing with no
      # bold at all reads perfectly well; the morning after the worst of these
      # came out that way on its own.
      text.gsub(SPAN_RX) { ::Regexp.last_match(1) }
    end

    def figure?(inner)
      inner.to_s.strip.match?(FIGURE_RX)
    end
  end
end
