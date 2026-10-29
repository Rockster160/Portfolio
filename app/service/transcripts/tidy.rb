module Transcripts
  # Puts right the words the recorder misheard, and nothing else.
  #
  # A machine transcription hears sounds and writes the likeliest word for
  # them, which is the right word most of the time and a word that merely
  # SOUNDS like it the rest - and the rest is concentrated exactly where the
  # value of a transcript is. "hand coating everything now" is what came back
  # from half an hour about writing software; `Sidekiq` arrives as `side kick`,
  # `async` as `a sink`, and every company and product name in the call is a
  # coin toss. Read later for what was actually said, those lines are the ones
  # that cannot be used.
  #
  # THE TEXT IS NEVER TAKEN FROM THE REPLY. What comes back is a list of
  # replacements - the words as the file has them, and what was said instead -
  # and each one is applied to the file here. So the shape of a turn cannot
  # change however the model answers: a reply that rewrote a sentence to read
  # better has nowhere to put it. This is the same mechanism as the quotes that
  # cut a wall of text in `Speakers`, for the same reason.
  #
  # AND IT IS NOT AN EDIT. The one thing a transcript is for is being read back
  # as what was said, so grammar, filler, false starts, repetition and the
  # order of the words all stay exactly as they arrived. A fix is a word the
  # machine got wrong; anything else is a second opinion on a sentence that was
  # already spoken out loud, and it is refused by `worth?` rather than trusted
  # not to arrive.
  #
  # WHAT IT HEARD IS KEPT. A mended turn carries `heard` - the line as the
  # recorder wrote it - so a fix can be read beside what it replaced and a
  # wrong one is visible rather than silently authoritative.
  module Tidy
    module_function

    MODEL = "gpt-5.4-mini".freeze

    # Characters of conversation per call. Smaller than the window the split
    # pass uses, because this one is read word by word rather than for the
    # shape of it, and a long stretch comes back having looked closely at the
    # first third of it.
    MOST_CHARS = 6_000

    # The ceiling on calls for one transcript. An hour of talking is inside it.
    MOST_CALLS = 12

    # Turns of what came just before, so a window does not open cold. A word
    # is only placeable from the sentences around it, and the first turn in a
    # window has none above it otherwise.
    BEFORE_TURNS = 2
    BEFORE_CHARS = 240

    # The longest stretch a fix may cover, and the shortest. A mishearing is a
    # word or a phrase; a `was` of eleven words is a sentence, and replacing a
    # sentence is the rewrite this refuses to do. Two characters is not enough
    # to be sure it was even found in the right place.
    MOST_WAS_WORDS = 6
    LEAST_WAS = 3

    # How alike the two must be. A mishearing SOUNDS like what was said, so it
    # is spelled almost the same: `coating` for `coding` is one letter. This is
    # the guard that keeps a rewrite out - a better sentence shares almost no
    # letters with the one it replaces, and it is dropped on arrival.
    LEAST_LIKE = 0.6

    Result = Struct.new(:ok, :mended, :turns, :error, keyword_init: true)

    # The chip the worker raises while it reads. Same shape as the split pass
    # and deliberately a different key: both can be on one transcript, one
    # after the other, and either taking the other's chip down would say the
    # work had finished while it was running.
    def key_for(transcript)
      "transcript:tidy:#{transcript.id}"
    end

    # Reads the whole conversation a window at a time and writes back only the
    # turns that changed. `again` is the press on the page: a transcript is
    # gone over once when it lands, and going over it a second time costs the
    # same calls to be told the same thing, so it is asked for rather than
    # assumed.
    def call(transcript, again: false, &progress)
      turns = Array(transcript.turns)
      return Result.new(ok: false, mended: 0, turns: 0, error: :empty) if turns.empty?
      return Result.new(ok: false, mended: 0, turns: 0, error: :done) if done?(transcript, again)

      mended = turns.map(&:dup)
      fixed, answered = walk(transcript, mended, &progress)

      # Not one window came back readable, so nothing has been gone over. The
      # stamp is withheld along with the turns: a transcript marked as checked
      # on the strength of an hour the model never answered for would never be
      # offered again.
      return Result.new(ok: false, mended: 0, turns: 0, error: :unreadable) if answered.zero?

      transcript.update!(turns: mended, tidied_at: Time.current)
      Result.new(ok: true, mended: fixed, turns: mended.count { |turn| turn["heard"].present? })
    end

    def done?(transcript, again)
      transcript.tidied_at.present? && !again
    end

    # ---- the walk ------------------------------------------------------------

    # A window at a time, in order, each one carrying the tail of the one
    # before it as context. The windows do not overlap: a turn read twice is a
    # turn fixed twice, and the second reading is looking at words the first
    # one already changed.
    def walk(transcript, turns)
      slices = windows(turns)
      total = [slices.size, MOST_CALLS].min
      fixed = 0
      answered = 0
      calls = 0

      slices.each do |window|
        break if calls >= MOST_CALLS

        calls += 1
        before = before(turns, window.first)
        said = ask(Prompt.input(turns, window, transcript, before: before))
        yield(calls, total) if block_given?
        found = parsed(said)
        next if found.nil?

        answered += 1
        fixed += apply(turns, window, found)
      end

      [fixed, answered]
    end

    # The turns grouped into windows by how much talking is in them rather than
    # how many turns there are: a cued export writes 400 turns of six words and
    # a pasted recording writes one of nine thousand, and a count of turns
    # makes one of those a call per sentence and the other a single call for
    # the lot. A turn longer than a window on its own is its own window.
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

    # Each fix against the turn it was found in and no other. The same few
    # words appear all over a conversation - a `was` copied out of turn 12 is
    # in turn 40 as well - and applied there it is a correction to a sentence
    # nobody read, made on the strength of a different one.
    def apply(turns, window, said)
      Array(said.to_h["fixes"]).sum { |fix|
        at = fix.to_h["turn"].to_i - 1
        next 0 unless window.include?(at)

        mend(turns[at], fix.to_h["was"].to_s.strip, fix.to_h["now"].to_s.strip)
      }
    end

    # One replacement, or nothing. `heard` is written the first time a turn is
    # touched and never again, so it holds the line as the recorder wrote it
    # rather than as the last pass left it.
    def mend(turn, was, now)
      return 0 unless worth?(was, now)

      said = turn["text"].to_s
      # The block form, because a replacement is text and not a template: a
      # `now` carrying a backslash would otherwise be read as a backreference.
      fixed = said.gsub(was) { now }
      fixed = said.gsub(/#{Regexp.escape(was)}/i) { now } if fixed == said
      return 0 if fixed == said

      turn["heard"] = said if turn["heard"].blank?
      turn["text"] = fixed
      1
    end

    # Is this a mishearing being put right, or an edit wearing one's clothes?
    # Everything that makes this pass safe is in here: short, close in length,
    # and spelled almost the same.
    def worth?(was, now)
      return false if was.blank? || now.blank? || was == now
      return false if was.length < LEAST_WAS || was.split.size > MOST_WAS_WORDS
      return false if now.split.size > MOST_WAS_WORDS + 1

      near?(was, now)
    end

    def near?(was, now)
      left = bare(was)
      right = bare(now)
      return false if left.empty? || right.empty?

      distance(left, right) <= ([left.length, right.length].max * (1 - LEAST_LIKE))
    end

    # Letters and digits only, because the question is what it SOUNDS like.
    # Spacing and punctuation are where a mishearing shows up most - `a sink`
    # for `async` is the same letters cut differently - and counting them as
    # differences would refuse exactly the fix that is most wanted.
    def bare(said)
      said.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end

    # Edit distance, on two stretches of a few words at most - anything longer
    # is refused above, so the cost of this is never a question.
    def distance(left, right)
      row = (0..right.length).to_a

      left.each_char.with_index do |letter, index|
        moved = [index + 1]
        right.each_char.with_index do |other, at|
          moved << [moved[at] + 1, row[at + 1] + 1, row[at] + (letter == other ? 0 : 1)].min
        end
        row = moved
      end

      row.last
    end

    # ---- the call ------------------------------------------------------------

    def ask(input)
      result = Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: input,
        input:        [{ role: :user, content: [{ type: :input_text, text: "Fix the words." }] }],
      )
      result[:ok] ? result[:text] : nil
    end

    # Asked for JSON and mostly given it. A fenced block or a line of preamble
    # is the ordinary failure and worth surviving; anything else is nil and the
    # window it covered stays as the recorder wrote it.
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
