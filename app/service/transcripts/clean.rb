module Transcripts
  # A version of the conversation that can be READ, kept beside the one that
  # was said.
  #
  # A machine transcription of somebody talking for half an hour is accurate
  # and nearly unreadable. "Um, my, my biggest things that I liked building
  # are usually, um, tools, like internal tools, especially" is what came out
  # of his mouth and it is four words of content behind a hedge in every
  # clause. Read back later for what he actually told them, those lines take
  # three passes of the eye each.
  #
  # THE WORDS THAT WERE SAID ARE NOT TOUCHED. `text` stays exactly as `Tidy`
  # left it and the cleaned version goes alongside it on the turn, under
  # `clean`, the same way `heard` keeps what the recorder wrote. So the page
  # can show either one and the record of what was said survives a cleaning
  # that went wrong - which matters more here than anywhere else in the chain,
  # because this is the one pass whose whole job is to change the words.
  #
  # AND THE DEBRIEF STILL READS THE SPOKEN ONE. How he did is a judgment about
  # how he actually talked: the circling, the hedge, the answer that checked
  # whether it had landed. Cleaned text is exactly the evidence of all three
  # removed, so a reading made off it would say the interview went better than
  # it did. This pass hangs off the words beside that reading, never in front
  # of it.
  #
  # WHAT COMES BACK IS REFUSED ON ARRIVAL, by `worth?`. Asked to clean a spoken
  # answer a model will improve it - tighten the argument, merge the three
  # sentences that circled one point, finish the thought he left hanging - and
  # every one of those produces a version he cannot practise, cannot learn
  # from, and would later believe he had said. The guards below are shaped at
  # that one failure: a cleaned turn has to be nearly as long as the turn it
  # came from, keep nearly all of its distinctive words, and keep every number
  # in it. A summary fails all three.
  module Clean
    module_function

    MODEL = "gpt-5.4-mini".freeze

    # Characters of conversation per call. Smaller than either of the other
    # passes, because this is the only one that writes the whole window back
    # out: the others answer with a short list about it. The window is bounded
    # by what the reply has to hold, not by what reading it needs.
    MOST_CHARS = 4_000

    # The ceiling on calls for one transcript. An hour of talking is inside it,
    # at the smaller window.
    MOST_CALLS = 16

    # Turns of what came just before, so a window does not open cold. A false
    # start is recognised from what the sentence was heading for, and the first
    # turn in a window has nothing above it otherwise.
    BEFORE_TURNS = 2
    BEFORE_CHARS = 240

    # How much of the turn has to survive. Cleaning takes out noise, which on a
    # thick spoken answer is a quarter of the characters and no more - so a
    # version at a third of the length is not a cleaned turn, it is a summary
    # of one. The ceiling is the other failure: a turn that came back LONGER
    # had something put into it.
    LEAST_OF_IT = 0.4
    MOST_OF_IT = 1.1

    # Below this the floor does not apply, because a short turn can honestly be
    # almost all noise - "Ooh. Um..." cleans to nothing at all, and that is the
    # right answer rather than a failure.
    SHORT_TURN = 80

    # How many of the turn's own words have to still be there. THIS IS THE
    # GUARD THAT CATCHES A REWRITE. Noise is a small, closed set of words;
    # everything else he said is the content, and a model that reached for a
    # better sentence reaches for different words to build it with. Length
    # alone does not catch that - a rewrite can be exactly as long.
    LEAST_KEPT = 0.8

    # The words a cleaned turn is allowed to lose, so losing them is not read
    # as a rewrite. Only the discourse furniture is here: nothing that names a
    # thing, a system, a person or an action. A list any wider would start
    # excusing the deletions this exists to refuse.
    FILLER = <<~WORDS.split.to_set.freeze
      basically essentially actually obviously honestly really literally
      kind sort like know mean just yeah yep okay sure right well
      sorry excuse guess think maybe probably thing things stuff
      gonna wanna kinda sorta
    WORDS

    Result = Struct.new(:ok, :cleaned, :turns, :error, keyword_init: true)

    # The chip the worker raises while it reads. Keyed per pass per transcript
    # like the others, so this one running does not take down the chip of the
    # reading it runs beside.
    def key_for(transcript)
      "transcript:clean:#{transcript.id}"
    end

    # Reads the whole conversation a window at a time and writes a cleaned
    # version onto the turns it could do. `again` is the press on the page: a
    # transcript is cleaned once when it lands, and doing it twice costs the
    # same calls to be given the same text back, so a second one is asked for
    # rather than assumed.
    def call(transcript, again: false, &progress)
      turns = Array(transcript.turns)
      return Result.new(ok: false, cleaned: 0, turns: 0, error: :empty) if turns.empty?
      return Result.new(ok: false, cleaned: 0, turns: 0, error: :done) if done?(transcript, again)

      cleaned = turns.map(&:dup)
      written, answered = walk(transcript, cleaned, &progress)

      # Not one window came back usable, so nothing has been cleaned. The stamp
      # is withheld along with the turns: a transcript marked as cleaned on the
      # strength of an hour the model never answered for would offer the page a
      # cleaned read that is the spoken one with a different label on it.
      return Result.new(ok: false, cleaned: 0, turns: 0, error: :unusable) if answered.zero?

      transcript.update!(turns: cleaned, cleaned_at: Time.current)
      Result.new(ok: true, cleaned: written, turns: cleaned.count { |turn| turn.key?("clean") })
    end

    def done?(transcript, again)
      transcript.cleaned_at.present? && !again
    end

    # ---- the walk ------------------------------------------------------------

    # A window at a time, in order, each one carrying the tail of the one
    # before it as context. The windows do not overlap: a turn cleaned twice
    # is cleaned the second time off words the first pass already replaced.
    def walk(transcript, turns)
      slices = windows(turns)
      total = [slices.size, MOST_CALLS].min
      written = 0
      answered = 0
      calls = 0

      slices.each do |window|
        break if calls >= MOST_CALLS

        calls += 1
        said = ask(Prompt.input(turns, window, transcript, before: before(turns, window.first)))
        yield(calls, total) if block_given?
        found = parsed(said)
        next if found.nil?

        answered += 1
        written += apply(turns, window, found)
      end

      [written, answered]
    end

    # The turns grouped into windows by how much talking is in them rather than
    # how many of them there are: a cued export writes 400 turns of six words
    # and a pasted recording writes one of nine thousand. A turn longer than a
    # window on its own is its own window.
    def windows(turns)
      found = [[]]
      size = 0

      turns.each_with_index do |turn, index|
        length = turn["text"].to_s.length
        if found.last.any? && (size + length) > MOST_CHARS
          found << []
          size = 0
        end
        found.last << index
        size += length
      end

      found.reject(&:empty?)
    end

    # What was said just before the window, as words. The end of each turn
    # rather than the start - the words nearest the window are the ones its
    # first sentence follows on from.
    def before(turns, edge)
      from = [edge - BEFORE_TURNS, 0].max
      turns[from...edge].to_a.map { |turn|
        said = turn["text"].to_s.strip
        said.length > BEFORE_CHARS ? "...#{said.last(BEFORE_CHARS).sub(/\A\S+\s/, "")}" : said
      }
    end

    # ---- what comes back -----------------------------------------------------

    # Each cleaned turn against the turn it was given for and no other. A reply
    # that numbered its entries from one rather than from the window would
    # otherwise write the first turn of the conversation over the first turn of
    # the window, every window after the first.
    def apply(turns, window, said)
      Array(said.to_h["clean"]).sum { |entry|
        at = entry.to_h["turn"].to_i - 1
        next 0 unless window.include?(at)

        write(turns[at], entry.to_h["text"].to_s.strip)
      }
    end

    # One cleaned turn, or nothing.
    #
    # A version identical to what was said is not written. There is nothing to
    # keep: the page falls back to `text` wherever `clean` is absent, so an
    # unchanged turn reads the same either way and storing it twice only makes
    # the row bigger. The key going on at all is what says this turn was looked
    # at and came back different.
    def write(turn, clean)
      said = turn["text"].to_s
      return 0 unless worth?(said, clean)
      return 0 if clean == said.strip

      turn["clean"] = clean
      1
    end

    # Is this the turn with its noise gone, or a better answer wearing one's
    # clothes? Everything that makes this pass safe is in here.
    def worth?(said, clean)
      return false if said.strip.empty?
      # A turn that was all noise cleans to nothing, which only an honestly
      # short turn can be. A long answer reduced to silence is a dropped turn.
      return clean.empty? if said.strip.length < SHORT_TURN
      return false if clean.empty?
      return false unless sized?(said, clean)
      return false unless numbers_kept?(said, clean)

      words_kept?(said, clean)
    end

    def sized?(said, clean)
      share = clean.length.to_f / said.strip.length
      share.between?(LEAST_OF_IT, MOST_OF_IT)
    end

    # Every number he said is still there. The cheapest guard in the file and
    # the one that matters most on these recordings: the figures are what an
    # answer is worth, they are the first thing a tightened sentence drops, and
    # a missing one is invisible on a page of prose.
    def numbers_kept?(said, clean)
      said.scan(/\d+/).uniq.all? { |number| clean.include?(number) }
    end

    # How much of what he said is still his words. Compared as sets of the
    # longer words, because repetition is exactly what this pass takes out - a
    # count would read "we had to, we had to" collapsing to "we had to" as half
    # the turn gone.
    def words_kept?(said, clean)
      was = content(said)
      return true if was.empty?

      kept = was & content(clean)
      (kept.size.to_f / was.size) >= LEAST_KEPT
    end

    # The words that say what the turn was about. Short words are skipped
    # because they are grammar rather than content and they survive any
    # rewrite, so counting them would dilute the measure toward passing.
    def content(said)
      words = said.to_s.downcase.scan(/[a-z0-9']+/)
      words.select { |word| word.length >= 4 && FILLER.exclude?(word) }.to_set
    end

    # ---- the call ------------------------------------------------------------

    def ask(input)
      result = Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: input,
        input:        [{ role: :user, content: [{ type: :input_text, text: "Clean these up." }] }],
      )
      result[:ok] ? result[:text] : nil
    end

    # Asked for JSON and mostly given it. A fenced block or a line of preamble
    # is the ordinary failure and worth surviving; anything else is nil and the
    # window it covered reads as it was spoken.
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
