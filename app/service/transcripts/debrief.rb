module Transcripts
  # Reads a recorded interview and says how it went.
  #
  # The third pass over a recording and the only one that is about HIM rather
  # than about the file: who was talking and what the words were are both
  # questions with a right answer, and this one is a judgment. It runs last
  # because it has to - feedback written off a transcript that still says "hand
  # coating everything now" is feedback on a sentence he did not say.
  #
  # ONE CALL, THE WHOLE CONVERSATION. The other two passes read a window at a
  # time because a mishearing is local; nothing here is. Whether he answered
  # the question they asked is a fact about two turns forty minutes apart, and
  # whether he ever closed is a fact about the end read against the beginning.
  # So the whole thing goes in one call, and what gets trimmed to fit is THEIR
  # longest turns - their pitch about the company is the one part of an
  # interview that says nothing about how he did.
  #
  # NOTHING IS WRITTEN WITHOUT A TURN BEHIND IT. Every note that judges him
  # names the line it is about, and a note naming a line that is not his - or
  # not there at all - is dropped here rather than trusted. That is the same
  # mechanism as the other two passes, for a different failure: the thing that
  # goes wrong with feedback is not a rewrite, it is generosity. A model asked
  # how an interview went will say it went well, at length, about an interview
  # it has partly imagined. A note has to point at something he said.
  #
  # AND HE HAS TO BE PLACED FIRST. Nobody marked as him means no turns are
  # his, which means every note would be dropped and the call paid for anyway,
  # so it refuses before it spends anything and the page asks him to tick which
  # speaker he is.
  module Debrief
    module_function

    # The judgment pass, so not the mini model the other two use. An interview
    # is one call either way and the whole product is the quality of the read;
    # this is the one place in a recording's handling where a better model is
    # obviously worth the few cents.
    MODEL = "gpt-5.4".freeze

    # Enough conversation that there is something to judge. Three exchanges is
    # a recording that cut out, and a confident debrief of it would be invented.
    LEAST_TURNS = 6

    # The whole conversation, in characters. An hour of two people talking
    # lands around 48,000, so most recordings go in untouched.
    MOST_CHARS = 48_000
    THEIRS_CHARS = 600

    # What is kept of a reply. Caps rather than trust: a `read` that arrived as
    # nine paragraphs is the essay this is not for, and eleven things to do
    # next time is a list nobody acts on.
    MOST_READ = 1_200
    MOST_SAID = 800
    MOST_STRONG = 3
    MOST_COST = 4
    MOST_MISSED = 4
    MOST_NEXT = 5

    Result = Struct.new(:ok, :notes, :error, keyword_init: true)

    def key_for(transcript)
      "transcript:debrief:#{transcript.id}"
    end

    # `again` is the press on the page. It is gone over once by itself when the
    # recording lands, and after that on request - partly because a second
    # reading costs another call to be told much the same thing, and partly
    # because the first one is worth re-running once the speakers have been
    # corrected and the words put right.
    def call(transcript, again: false, &progress)
      turns = Array(transcript.turns)
      return Result.new(ok: false, notes: 0, error: :thin) if turns.size < LEAST_TURNS
      return Result.new(ok: false, notes: 0, error: :done) if done?(transcript, again)
      return Result.new(ok: false, notes: 0, error: :unplaced) unless placed?(transcript)

      said = ask(Prompt.input(transcript, lines(transcript, turns)))
      progress&.call(1, 1)
      found = parsed(said)
      return Result.new(ok: false, notes: 0, error: :unreadable) if found.nil?

      written = read(transcript, turns, found)
      return Result.new(ok: false, notes: 0, error: :empty) if written["read"].blank?

      transcript.update!(debrief: written, debriefed_at: Time.current)
      Result.new(ok: true, notes: counted(written), error: nil)
    end

    def done?(transcript, again)
      transcript.debriefed_at.present? && !again
    end

    # Is any turn his? A recording whose speakers nobody has settled has no
    # answer to "how did I do", because it does not know which half of it is
    # him.
    def placed?(transcript)
      Array(transcript.turns).any? { |turn| transcript.mine?(turn["speaker"].to_s) }
    end

    def counted(written)
      [:strongest, :cost, :missed, :next].sum { |key| written[key.to_s].to_a.size }
    end

    # ---- what goes in --------------------------------------------------------

    # The conversation, numbered the same way the page numbers it, with his
    # side marked. Numbers are what every note comes back pointing at, so they
    # are over the whole conversation and not over anything that was kept.
    def lines(transcript, turns)
      over = turns.sum { |turn| turn["text"].to_s.length } - MOST_CHARS
      cut = cuts(transcript, turns, over)

      turns.each_with_index.map { |turn, at|
        said = turn["text"].to_s.strip
        said = "#{said.first(THEIRS_CHARS)}…" if cut.include?(at)
        "#{at + 1}. [#{Prompt.who(transcript, turn)}] #{said}"
      }
    end

    # Which turns to shorten when there is more talking than fits, longest
    # first and never his. Their long stretches are the company being described
    # and the role being explained - worth having, not worth having in full,
    # and the only part of the recording that is not evidence about him.
    def cuts(transcript, turns, over)
      taken = Set.new
      return taken if over <= 0

      theirs = turns.each_with_index.reject { |turn, _at|
        transcript.mine?(turn["speaker"].to_s)
      }

      theirs.sort_by { |turn, _at| -turn["text"].to_s.length }.each do |turn, at|
        break if over <= 0

        length = turn["text"].to_s.length
        next if length <= THEIRS_CHARS

        taken << at
        over -= length - THEIRS_CHARS
      end

      taken
    end

    # ---- what comes back -----------------------------------------------------

    # The reply, cut down to what is worth keeping and nothing that points
    # nowhere. Stored as it will be read, so the page renders a row rather than
    # deciding whether to trust one.
    def read(transcript, turns, found)
      {
        "read"      => found["read"].to_s.strip.truncate(MOST_READ),
        "strongest" => moments(transcript, turns, found["strongest"], [:why], MOST_STRONG),
        "cost"      => moments(transcript, turns, found["cost"], [:what, :instead], MOST_COST),
        "missed"    => missed(found["missed"]),
        "next"      => notes(found["next"], MOST_NEXT),
        "model"     => MODEL,
      }
    end

    # A note about a moment, against the turn it is about - and only if that
    # turn is one of his. A note on their line is a note about how the
    # interviewer did, which is somebody else's debrief; a note on a turn that
    # is not there is a note about a conversation that did not happen.
    def moments(transcript, turns, found, fields, cap)
      Array(found).filter_map { |row|
        at = row.to_h["turn"].to_i - 1
        next if turns[at].nil? || at.negative?
        next unless transcript.mine?(turns[at]["speaker"].to_s)

        said = fields.index_with { |field| row.to_h[field.to_s].to_s.strip.truncate(MOST_SAID) }
        next if said[fields.first].blank?

        said.transform_keys(&:to_s).merge("turn" => at + 1)
      }.first(cap)
    end

    # The notes that are not about one turn - a thing never said, a question
    # never asked. `where` is in words, because a moment that never happened
    # has no line number.
    def missed(found)
      Array(found).filter_map { |row|
        what = row.to_h["what"].to_s.strip.truncate(MOST_SAID)
        next if what.blank?

        { "what" => what, "where" => row.to_h["where"].to_s.strip.truncate(MOST_SAID) }
      }.first(MOST_MISSED)
    end

    def notes(found, cap)
      Array(found).map { |said| said.to_s.strip.truncate(MOST_SAID) }.compact_blank.first(cap)
    end

    # ---- the call ------------------------------------------------------------

    # Reasoning on, unlike the two mechanical passes: the question is what the
    # conversation added up to, and an answer written off the top of the file is
    # the generic interview advice this exists instead of.
    def ask(input)
      result = Buddy::GPT::Client.new(model: MODEL, reasoning_effort: :medium).stream(
        instructions: input,
        input:        [{ role: :user, content: [{ type: :input_text, text: "How did I do?" }] }],
      )
      result[:ok] ? result[:text] : nil
    end

    def parsed(said)
      raw = said.to_s.strip.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "")
      json = raw[/\{.*\}/m]
      return nil if json.nil?

      JSON.parse(json)
    rescue JSON::ParserError
      nil
    end
  end
end
