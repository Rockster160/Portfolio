# WHAT THEY TOLD HIM TO PREPARE, lifted out of their own mail.
#
# "To make the most of this conversation, come ready to walk through:" and then
# three bullets - an AI system he shipped and how he measured it, a product
# decision he owned, a disagreement and what he did next. That is the interview,
# written down by the person booking it, a week before it happens.
#
# It was already on the board, because a beat keeps the whole message. It was
# nowhere a brief would notice it: three paragraphs into the ninth of twelve
# mails, read for who and when, and the hour was prepared for the ROUND rather
# than for the three things they said out loud they were going to ask.
#
# A RUNDOWN ARRIVES ONCE AND IS SPENT NOWHERE. The other shape of it is the
# recruiter's first mail laying out all four rounds and what each one covers -
# the most useful thing on the application, and thirty beats old by the time the
# round it describes is actually booked. So these are read off EVERY beat, never
# off the recent ones, and each one says which round it names so the one that
# belongs to the conversation an hour away can be told from the three that do
# not.
#
# CUES RATHER THAN A MODEL. The mail that does this is strikingly uniform -
# somebody is writing an instruction, so they write it as one: come ready to,
# be prepared to, here is what to expect, the process is. A cue plus the list
# under it is the whole passage, and the cost of reading one wrong is a stray
# paragraph in a prompt that already carries twelve mails whole. The cost of a
# model here is a call on every beat of every application on every page load.
module InterviewAsks
  module_function

  # The lines that mean somebody is telling him what this conversation will be.
  # Tightened where a phrase is also boilerplate: `interview process` on its own
  # appears in every "we will be in touch" sign-off, so it has to be somebody
  # SAYING something about the process.
  CUES = [
    /\bcome (?:ready|prepared)\b/i,
    /\b(?:be|being) (?:ready|prepared) (?:to|for|with)\b/i,
    /\bplease (?:prepare|have ready|bring|come prepared)\b/i,
    /\bto (?:help you )?prepare\b/i,
    /\bwhat to expect\b/i,
    /\bexpect to (?:be asked|cover|discuss|walk|talk)\b/i,
    /\b(?:interview|hiring) process (?:is|will|looks|consists|has|includes)\b/i,
    /\b(?:the|our) process (?:is|will be|looks like|consists of|has)\b/i,
    /\b(?:rounds|stages|steps) (?:are|will be|consist|include)\b/i,
    /\bwe(?:'ll| will| would like to) (?:ask|cover|focus|dive|explore|discuss)\b/i,
    /\byou(?:'ll| will) be (?:asked|expected)\b/i,
    /\bthis (?:round|conversation|interview|call|session) will\b/i,
    /\b(?:walk|talk) (?:me|us) through\b/i,
    /\brecommend (?:reviewing|reading|looking|familiari)/i,
    /\breview (?:our|the|these|this)\b/i,
    /\bfamiliarise?\b/i,
    /\bfamiliarize\b/i,
  ].freeze

  # The rounds a passage can be about, keyed exactly as the brief's own KIND is
  # - see InterviewPrep::KIND_LABELS. ONE vocabulary end to end: an ask found to
  # be about `manager` is an ask about the conversation a brief that opens
  # `KIND: manager` is being written for, and the two can be matched up without
  # anything translating between them.
  ROUNDS = {
    recruiter:  /recruiter|screening call|phone screen|intro(?:ductory)? call/i,
    manager:    /hiring manager|manager (?:call|interview|round|conversation|chat)/i,
    technical:  /technical|coding|pairing|live code|system design|architecture|take.?home/i,
    behavioral: /behavio/i,
    panel:      /panel/i,
    onsite:     /onsite|on-site|in.person/i,
  }.freeze

  # A list under the cue is part of the instruction, and without it the cue says
  # nothing at all: "come ready to walk through:" is not the ask, the three
  # bullets are.
  BULLET = /\A\s*(?:[-*•◦‣]|\d{1,2}[.)]|[a-z][.)])\s+/i

  # How much of one passage to keep. Long enough for a four-round rundown with a
  # line under each; short enough that a mail which trips a cue in its boilerplate
  # cannot donate a page to the brief.
  MAX_SAID = 1_200

  # How many to carry off one application. More than this is a cue matching
  # something it should not, and a prompt is better served by the first few.
  MOST_ASKS = 6

  # One passage, and the beat it was found in.
  Ask = Struct.new(:note, :said, :rounds, :fits_event, keyword_init: true) do
    def occurred_at
      note&.occurred_at
    end

    # Does this one name the round `kind`? `kind` is an InterviewPrep kind.
    def about?(kind)
      rounds.include?(kind.to_s.to_sym)
    end

    # What to call the rounds it names, for a person reading the row.
    def round_labels
      rounds.filter_map { |round| InterviewPrep::KIND_LABELS[round.to_s] }
    end

    # One line of provenance, then the words as they were written. For a prompt
    # rather than for a page: which beat said it, when, which round it is about,
    # and whether that round is the one an hour away.
    def as_row(user)
      named = round_labels.map(&:downcase)
      head = [
        "#{note.tag_label} beat",
        occurred_at&.in_time_zone(user.timezone)&.strftime("%b %-d"),
        ("about the #{named.join(" and the ")}" if named.any?),
        ("and that is the round being prepared for" if fits_event),
      ].compact.join(", ")

      "- #{head}:\n\n#{said.indent(2)}"
    end
  end

  # Every passage in one mail that tells him what to prepare.
  #
  # Read in BLOCKS - a paragraph, or a run of bullets - because that is the unit
  # somebody writes an instruction in. A cue anywhere in a block takes the whole
  # block, plus the list underneath it, plus the one paragraph underneath a block
  # that ended on a colon and so was obviously pointing at it.
  #
  # `lead` is the paragraph ABOVE the cue, and it is kept for one reason: the
  # instruction almost never says which round it is for, and the sentence
  # introducing it almost always does. "a 30-minute Zoom interview with the
  # hiring manager, Evelyn Sharp" is the line before "come ready to walk
  # through:", and it is the only thing in the mail that says which of four
  # conversations these three bullets belong to.
  def found_in(text)
    blocks = blocks_in(text)
    found = []
    taken = []

    blocks.each_with_index do |block, index|
      next if taken.include?(index) || !cued?(block)

      reach = [index, *trailing(blocks, index)]
      taken.concat(reach)
      found << {
        said: reach.map { |at| blocks[at] }.join("\n\n").first(MAX_SAID),
        lead: (index.positive? ? blocks[index - 1] : ""),
      }
    end
    found
  end

  # The passages themselves, which is what gets read and shown.
  def passages(text)
    found_in(text).pluck(:said)
  end

  # The asks on one application, oldest first - the order they were said in,
  # which is the order a process gets explained.
  #
  # EVERY beat, because the rundown is the first mail and the round it describes
  # is booked a month later. `event` is the booking being prepared for, where
  # there is one: an ask whose round the calendar row also names is the one that
  # is actually about the hour coming up.
  def for(application, event: nil)
    wanted = rounds_in(event_text(event))

    gathered = application.notes.ordered.flat_map { |note|
      found_in(note.body).map { |hit|
        # The passage first, and the line above it only where the passage names
        # no round at all - a rundown says which rounds it is about in its own
        # words, and reading its lead in too would hand it whatever the mail
        # happened to mention before it.
        rounds = rounds_in(hit[:said]).presence || rounds_in(hit[:lead])
        Ask.new(
          note:       note,
          said:       hit[:said],
          rounds:     rounds,
          fits_event: wanted.any? && rounds.intersect?(wanted),
        )
      }
    }
    pick(same_ask_once(gathered))
  end

  # A REPLY QUOTES THE MAIL IT IS ANSWERING, so the ask they wrote once arrives
  # again under every "On Friday, Tyler wrote:" after it. Kept where it was
  # actually said, which is the oldest of them. Compared on the letters alone,
  # because the second copy comes back wrapped differently and with a `>` down
  # the side of it.
  def same_ask_once(asks)
    asks.uniq { |ask| ask.said.gsub(/[^a-z0-9]/i, "").downcase }
  end

  # WHICH ONES, when the cues have matched more times than a prompt can carry.
  # The ones the booking is about first and the newest after them: an ask from
  # last week is about the round being booked, and the one in the first mail has
  # usually been answered already. Then back into the order they were said in,
  # because that is how a process reads.
  def pick(asks)
    return asks if asks.size <= MOST_ASKS

    ranked = asks.each_with_index.sort_by { |ask, at| [ask.fits_event ? 0 : 1, -at] }
    ranked.first(MOST_ASKS).map(&:last).sort.map { |at| asks[at] }
  end

  def blocks_in(text)
    text.to_s.gsub("\r\n", "\n").split(/\n{2,}/).map(&:strip).reject(&:empty?)
  end

  def cued?(block)
    CUES.any? { |cue| block.match?(cue) }
  end

  # The blocks that belong to the cued one: every list under it, and a single
  # paragraph where the cue block ended on a colon and the next block is not a
  # list - "the process is as follows:" followed by a sentence saying what it is.
  def trailing(blocks, index)
    kept = []
    at = index + 1
    while (block = blocks[at])
      break unless bullets?(block)

      kept << at
      at += 1
    end
    return kept if kept.any? || !blocks[index].end_with?(":")
    return kept if blocks[index + 1].nil?

    kept << (index + 1)
    kept
  end

  def bullets?(block)
    lines = block.lines.map(&:strip).reject(&:empty?)
    lines.any? && lines.all? { |line| line.match?(BULLET) }
  end

  def rounds_in(text)
    said = text.to_s
    ROUNDS.filter_map { |round, words| round if said.match?(words) }
  end

  # What the booking itself says it is. The location counts: "Zoom" says nothing
  # but an address in their office says onsite.
  def event_text(event)
    return "" if event.nil?

    [event.name, event.notes, event.location].compact.join(" ")
  end
end
