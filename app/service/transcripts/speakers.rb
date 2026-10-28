module Transcripts
  # Works out who was talking, run on every transcript the moment it lands.
  #
  # ONE DROP, WHATEVER IS NEEDED. What comes out of a recorder is never the same
  # twice - a VTT with `Speaker 1` and `Speaker 2`, a VTT that heard one voice
  # and labelled the lot `Unknown`, a phone transcription that is half an hour
  # of unbroken text - and the question afterwards is always the same one:
  # which of this did I say. So the shape of the file decides what this does,
  # rather than him deciding and pressing something:
  #
  #   nobody named, one turn    - a wall of text. Where the handovers are has to
  #                               be found before anything can go on a side.
  #   nobody named, many turns  - the turns are already cut on the timings, so
  #                               only WHO is missing.
  #   people named              - the labels are fine; which one is HIM is not,
  #                               and that is the one thing it is read for.
  #
  # TWO SIDES, NOT A CAST, on the first two. Telling three interviewers apart
  # needs the audio; every voice on the employer's side lands on one label, and
  # the only thing the split has to get right is the handovers. A file that
  # named people keeps its own labels - they are better than anything this
  # could invent - and gets told which is which instead.
  #
  # A NAME IS ONLY KEPT WHEN IT WAS SAID. `heard_name` throws away any name
  # that is not in the words, for the reason `JobTranscript#ingest!` named
  # nobody at all: a name guessed onto a quote he reads back later is worse
  # than no name.
  module Speakers
    module_function

    MODEL = "gpt-5.4-mini".freeze

    ME = "Me".freeze
    THEM = "Them".freeze
    UNKNOWN = TranscriptParser::UNKNOWN

    # Turns per call. Small enough that a chunk whose answer comes back the
    # wrong length costs a minute of the conversation rather than all of it, and
    # big enough that the model can see a handover coming.
    MOST_TURNS = 40

    # Characters of an unbroken wall of text per call. Roughly ten minutes of
    # talking, and well inside what comes back as a reliable list of quotes -
    # asked for an hour at once the replies thin out towards the end and whole
    # minutes come back as one turn.
    BLOB_CHARS = 9_000

    # The ceiling on calls for one transcript, both paths. An hour of talking is
    # inside it; past that the tail is left unplaced and said so, rather than
    # spending without a limit on a file somebody dropped in by mistake.
    MOST_CALLS = 10

    # The shortest quote that may cut the text. A handful of words appears over
    # and over in a conversation ("and so I"), and a cut made on one lands in
    # the wrong paragraph.
    LEAST_QUOTE = 12

    # Text past the last cut that is worth leaving UNPLACED rather than letting
    # the last turn swallow it. Under this it is the end of that turn.
    TAIL_SLACK = 400

    # How much of a window a call has to get through for the turn running past
    # its end to be worth re-reading. Under this the call made no ground - a
    # single answer ran the length of the window - and handing the next one the
    # same text costs a call to be told the same thing.
    LEAST_GROUND = 0.2

    # What the cut's `who` means. Anything else is dropped, which is what keeps
    # a reply inventing `Speaker 3` out of the transcript.
    SIDES = { "m" => ME, "t" => THEM }.freeze
    LETTERS = SIDES.invert.freeze

    # How much of what was already settled rides along into the next call. A
    # window starting cold opens mid-answer with no way to tell whose answer it
    # is: the stretch before it is the only thing that says whether the voice
    # carrying on is the one that was asked or the one that asked. Three turns
    # because the handover before the window is what settles it and the one
    # before that says which way it was going; more is paid for on every call
    # and answers the same question twice.
    BEFORE_TURNS = 3

    # Of each of those turns, the END - the words nearest the window, which are
    # the ones the opening of it is a reply to. A long answer's first sentence
    # says nothing about what is happening four minutes later.
    BEFORE_CHARS = 240

    Result = Struct.new(:ok, :placed, :unplaced, :error, keyword_init: true)

    # The chip the worker raises while it reads, and the one the transcript
    # page looks for to say that something is happening. Here rather than in
    # either of them because a page asking a different question than the worker
    # answered is a page that says nothing is running while it runs.
    def key_for(transcript)
      "transcript:speakers:#{transcript.id}"
    end

    # The whole pass. Returns a Result either way: nothing raises at the caller,
    # because a transcript this could not read is exactly where it was.
    # `progress` is called with how many calls are done and how many there are
    # to make, so whatever raised the pass can say that it is moving. A pass
    # nobody is watching passes no block and nothing here knows the difference.
    def call(transcript, &progress)
      turns = Array(transcript.turns)
      return Result.new(ok: false, error: :empty) if turns.empty?
      return Result.new(ok: false, error: :settled) if transcript.speakers.present?
      return name_labels(transcript) unless transcript.unlabelled?

      split = (
        if turns.size > 1
          from_turns(transcript, turns, &progress)
        else
          from_blob(transcript, turns, &progress)
        end
      )
      return split if split.is_a?(Result)

      # Nothing placed is a failed pass, not a finished one: the transcript is
      # left exactly as it was rather than written over with a page of turns
      # that still say nobody.
      counted = counted(split)
      return Result.new(ok: false, error: :unreadable) if counted.placed.zero?

      write!(transcript, split)
      counted
    end

    # ---- the file named people, it just never said which one is him ----------

    # The labels stay exactly as the recorder wrote them. All that is written is
    # the one thing he would otherwise tick by hand on every upload: which label
    # is his, and the name of anybody who said their name out loud.
    def name_labels(transcript)
      found = parsed(ask(Prompt.labels_input(transcript))).to_h["labels"]
      named = placed(transcript, Array(found))
      return Result.new(ok: false, error: :unreadable) if named.empty?

      transcript.update!(speakers: named)
      Result.new(ok: true, placed: named.size, unplaced: transcript.labels.size - named.size)
    end

    # ONE of them is him. A reply that ticks two is answering a different
    # question, and two labels both claiming his side is the one shape that
    # makes the page unreadable - so the first one marked keeps it.
    def placed(transcript, found)
      known = transcript.labels
      spoken = transcript.turns.pluck("text").join(" ").downcase
      mine = false

      found.each_with_object({}) { |entry, named|
        label = entry.to_h["label"].to_s
        next unless known.include?(label) && named[label].nil?

        his = !mine && entry.to_h["side"].to_s.downcase.start_with?("m")
        mine ||= his
        named[label] = { "name" => heard_name(entry.to_h["name"], spoken).to_s, "me" => his }
      }
    end

    # A name is kept only if it is SAID somewhere in the conversation - somebody
    # introducing themselves, or being thanked by name. Anything else is a guess
    # dressed as a reading, and it is thrown away rather than put on the page.
    def heard_name(given, spoken)
      name = given.to_s.strip
      return nil if name.length < 2 || spoken.exclude?(name.downcase)

      name
    end

    # ---- the turns are already cut -------------------------------------------

    # One letter per turn, so the answer can be CHECKED: a chunk that comes back
    # the wrong length is thrown away whole and those turns stay unplaced. The
    # alternative - taking a short answer and lining it up from the top - puts
    # every turn after the miscount on the wrong side, which reads as a working
    # split and is worse than a gap.
    def from_turns(transcript, turns)
      placed = turns.map { |turn| turn.merge("speaker" => UNKNOWN) }
      total = calls_for(turns.size, MOST_TURNS)
      calls = 0

      turns.each_slice(MOST_TURNS).with_index do |slice, chunk|
        break if calls >= MOST_CALLS

        calls += 1
        offset = chunk * MOST_TURNS
        before = settled(placed.first(offset))
        said = ask(Prompt.turns_input(slice, transcript, offset: offset, before: before))
        yield(calls, total) if block_given?
        letters = letters(said, slice.size)
        next if letters.nil?

        letters.each_with_index { |letter, index| placed[offset + index]["speaker"] = letter }
      end

      placed
    end

    # The tail of what is already placed, as the next call is given it. A chunk
    # whose answer was thrown away leaves its turns on UNKNOWN, and those are
    # left out rather than handed over as a side they were never put on.
    def settled(placed)
      placed.reverse.take_while { |turn| turn["speaker"] != UNKNOWN }.first(BEFORE_TURNS).reverse.map { |turn|
        said(LETTERS[turn["speaker"]], turn["text"])
      }
    end

    # The reply, as one side per turn, or nil if it cannot be trusted that far.
    def letters(said, count)
      sides = parsed(said).to_h["sides"].to_s.downcase.gsub(/[^mt]/, "")
      return nil unless sides.length == count

      sides.chars.map { |letter| SIDES.fetch(letter) }
    end

    # ---- one wall of text ----------------------------------------------------

    # Walked a window at a time, each window starting where the last one's last
    # cut was found. That cut is DROPPED on the way out and re-found by the next
    # call, because its turn runs past the end of the window and the model
    # cannot see where it ends.
    #
    # The window SLIDES rather than landing fresh: the last few turns already
    # settled go with it, as context and not as text to cut again. Without them
    # a window opens in the middle of a conversation with nothing to say who is
    # talking - and the first few turns of one are the ones that put every turn
    # after them on a side, because a conversation read as alternating is read
    # from wherever it was picked up.
    def from_blob(transcript, turns)
      text = turns.first.to_h["text"].to_s
      return Result.new(ok: false, error: :empty) if text.strip.empty?

      cuts = []
      at = 0
      reached = 0
      calls = 0
      total = calls_for(text.length, BLOB_CHARS)

      while at < text.length && calls < MOST_CALLS
        calls += 1
        window = text[at, BLOB_CHARS].to_s
        before = before(text, cuts, at)
        found = locate(window, ask(Prompt.cuts_input(window, transcript, before: before)), at)
        yield(calls, total) if block_given?
        break if found.empty?

        reached = at + window.length
        # The end of the window is the end of the file: there is no next call to
        # re-find the last cut, so it stays.
        ending = window.length < BLOB_CHARS
        last = (ending ? nil : found.pop)
        cuts.concat(found)

        # A window whose last handover sits near its own start made no ground,
        # and dropping that cut to re-find it would spend the next call reading
        # the same stretch again - which is how ten calls cover one minute of a
        # monologue. It is kept instead and the walk carries on from the end of
        # the window, so a turn longer than a window arrives as two turns on
        # the same side, which reads as one.
        if last && last[:at] - at < (BLOB_CHARS * LEAST_GROUND)
          cuts << last
          at = reached
          next
        end

        break if last.nil?

        reached = last[:at]
        at = last[:at]
      end

      return Result.new(ok: false, error: :unreadable) if cuts.empty?

      from_cuts(text, cuts, reached)
    end

    # The last few settled turns as words, ending where the window begins. The
    # cut that was popped is not among them - it is the turn the next window
    # opens with, and handing it over as settled would be answering the
    # question the call is being asked.
    def before(text, cuts, edge)
      taken = cuts.last(BEFORE_TURNS)
      taken.each_with_index.map { |cut, index|
        stop = taken[index + 1].to_h[:at] || edge
        said(LETTERS[cut[:side]], text[cut[:at]...stop].to_s)
      }
    end

    # One turn as the prompt takes it: which side, and the tail of what they
    # said. Nothing is sliced mid-word - a half word at the front reads as a
    # mistranscription, and this is the one place the model is shown text it is
    # not meant to match against the file.
    def said(letter, text)
      kept = text.to_s.strip
      kept = "...#{kept.last(BEFORE_CHARS).sub(/\A\S+\s/, "")}" if kept.length > BEFORE_CHARS
      { side: letter, said: kept }
    end

    # How many calls a file this size takes, as a number to count up to rather
    # than an exact one: a window ends at its last handover, so a long turn
    # costs a call that covered less than the whole window.
    def calls_for(size, each)
      [(size / each.to_f).ceil, MOST_CALLS].min.clamp(1, MOST_CALLS)
    end

    # Where each quote actually is in the text, in order. A quote that is not
    # there is dropped rather than placed approximately: the turn before it
    # swallows a few seconds, which is the failure that reads as a transcript
    # and not as a lie.
    def locate(window, said, base)
      found = parsed(said).to_h["turns"]
      from = 0

      Array(found).filter_map { |cut|
        side = SIDES[cut.to_h["who"].to_s.strip.downcase[0].to_s]
        quote = cut.to_h["starts"].to_s.strip
        next if side.nil? || quote.length < LEAST_QUOTE

        at = index_of(window, quote, from)
        next if at.nil?

        from = at + 1
        { at: base + at, side: side }
      }
    end

    # Exact first, then case-insensitively: a reply that capitalised the opening
    # of a sentence the transcript left lowercase is still pointing at the right
    # words.
    def index_of(window, quote, from)
      window.index(quote, from) || window.downcase.index(quote.downcase, from)
    end

    # `reached` is how far into the text the calls actually got. A long stretch
    # past it is NOT handed to the last turn - that would read as the right
    # person saying words nobody placed - so it goes in unplaced, where the page
    # shows it as a turn with nobody on it.
    def from_cuts(text, cuts, reached)
      edge = (text.length - reached > TAIL_SLACK ? reached : text.length)
      stop = cuts.each_with_index.map { |_cut, index| cuts[index + 1].to_h[:at] || edge }

      built = cuts.each_with_index.filter_map { |cut, index|
        # Whatever came before the first cut rides on it. It is the greeting
        # nobody quoted, and a turn of its own with nobody on it would be the
        # first thing on the page.
        starts = index.zero? ? 0 : cut[:at]
        said = text[starts...stop[index]].to_s.strip
        turn(cut[:side], said) if said.present?
      }

      tail = text[edge..].to_s.strip
      built << turn(UNKNOWN, tail) if tail.present?
      built
    end

    def turn(side, said)
      # `raw` stays what the file said - nothing. The side is a reading of the
      # words, and `JobTranscript#reassign!` moves a turn by writing `speaker`,
      # so a correction by hand and a correction in bulk stay the same mechanism
      # they are for a transcript that arrived labelled.
      { "raw" => UNKNOWN, "speaker" => side, "at" => nil, "to" => nil, "text" => said }
    end

    # ---- the call, and what comes back ---------------------------------------

    def ask(input)
      result = Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: input,
        input:        [{ role: :user, content: [{ type: :input_text, text: "Split it." }] }],
      )
      result[:ok] ? result[:text] : nil
    end

    # Asked for JSON and mostly given it. A fenced block or a line of preamble
    # is the ordinary failure and worth surviving; anything else is nil and the
    # turns it covered stay unplaced.
    def parsed(said)
      raw = said.to_s.strip.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "")
      json = raw[/\{.*\}/m]
      return nil if json.nil?

      JSON.parse(json)
    rescue JSON::ParserError
      nil
    end

    def write!(transcript, turns)
      named = transcript.speakers.to_h
      [ME, THEM].each do |side|
        next if named[side].present? || turns.none? { |turn| turn["speaker"] == side }

        named[side] = { "name" => side, "me" => side == ME }
      end

      transcript.update!(turns: turns, speakers: named)
    end

    def counted(turns)
      Result.new(
        ok:       true,
        placed:   turns.count { |turn| turn["speaker"] != UNKNOWN },
        unplaced: turns.count { |turn| turn["speaker"] == UNKNOWN },
      )
    end
  end
end
