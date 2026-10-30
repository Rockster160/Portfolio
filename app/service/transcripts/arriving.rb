module Transcripts
  # A recording the laptop made by itself, arriving the moment the call ends.
  #
  # TWO STREAMS, SO WHO SAID WHAT IS NOT A GUESS. The recorder captures his
  # microphone and the call's own audio separately and reads each one on its
  # own, so every word out of the first is his and every word out of the second
  # is theirs. Nothing here has to work out who was talking - the pass that
  # does that for an uploaded file refuses this one as already settled, which
  # is exactly right.
  #
  # IT SENDS SEGMENTS; THE TURNS ARE BUILT HERE. What comes off a speech model
  # is a few seconds of words at a time, which is not how a conversation reads.
  # Stitching those into turns is one rule - the same two-second gap the file
  # parser uses - and it lives here where it is tested rather than on the
  # laptop in a second copy.
  #
  # ONE CLOCK. Both streams are stamped against the same start, so a segment's
  # offset means the same thing whichever side it came from. That is what makes
  # interleaving them honest, and it is why the offsets are kept as they arrive
  # rather than being renumbered per side.
  class Arriving
    GAP = TranscriptParser::GAP
    MINE = "Me".freeze
    THEIRS = "Them".freeze

    # Their side is one stream, so it is one speaker here. A panel of three
    # comes back as `Them` and stays that way: separating voices inside one
    # mixed stream is the guesswork this whole shape exists to avoid.
    SIDES = { "me" => MINE, "them" => THEIRS }.freeze

    def self.call(user, given) = new(user, given).call

    def initialize(user, given)
      @user = user
      @given = given.to_h.symbolize_keys
    end

    # The transcript, filed if the clock says which interview it was. Nil when
    # there was nothing in it worth keeping, which is an answer rather than an
    # error - the recorder is told to drop what it can, and this is the backstop.
    def call
      rows = turns
      return nil if rows.empty?

      transcript = JobTranscript.new(
        user:        @user,
        title:       title,
        occurred_at: started,
        source:      source,
        speakers:    speakers,
        turns:       rows,
      )
      transcript.save!
      Filing.call(transcript)
      start_reading(transcript)
      transcript
    end

    private

    # Both sides' segments in one order, stitched into turns. Sorted by the
    # clock rather than taken stream by stream, because the conversation IS the
    # interleaving - and a sort that is stable on equal offsets keeps a reply
    # that began in the same moment behind what it was replying to.
    def turns
      found = segments.sort_by.with_index { |row, at| [row[:at], at] }
      found.each_with_object([]) { |row, built|
        last = built.last
        if last && last["speaker"] == row[:speaker] && (row[:at] - last["to"]) <= GAP
          last["to"] = row[:to]
          last["text"] = "#{last["text"]} #{row[:text]}".squish
        else
          built << turn(row)
        end
      }
    end

    def turn(row)
      {
        "raw"     => row[:speaker],
        "speaker" => row[:speaker],
        "at"      => row[:at],
        "to"      => row[:to],
        "text"    => row[:text],
      }
    end

    # What the recorder sent, cleaned up and nothing else: a side this does not
    # recognise is dropped rather than guessed at, because a turn on the wrong
    # side of a conversation is worse than a turn that is missing.
    def segments
      Array(@given[:segments]).filter_map { |given|
        row = given.to_h.symbolize_keys
        side = SIDES[row[:who].to_s.downcase]
        said = row[:text].to_s.strip
        next if side.nil? || said.empty?

        at = row[:at].to_f
        { speaker: side, at: at, to: [row[:to].to_f, at].max, text: said }
      }
    end

    # Named, because the whole point of two streams is that one of them is him.
    # Their side is labelled with whatever the recording knows - the site, the
    # app - so a conversation reads as having been with somebody rather than
    # with `Them`, and renaming it is the ordinary form on the page.
    def speakers
      {
        MINE   => { "name" => @user.first_name, "me" => true },
        THEIRS => { "name" => THEIRS, "me" => false },
      }
    end

    def source
      given = (@given[:source] || {}).to_h.symbolize_keys
      {
        "app"    => given[:app].to_s.strip.presence,
        "bundle" => given[:bundle].to_s.strip.presence,
        "host"   => given[:host].to_s.strip.presence,
        "url"    => given[:url].to_s.strip.presence,
      }.compact
    end

    # Read in HIS zone rather than the server's, so a stamp the recorder sent
    # without an offset still means the time it was on the laptop. An ISO one
    # carries its own and is unaffected.
    def started
      @user.parse_time(@given[:started_at].to_s) || Time.current
    rescue ArgumentError
      Time.current
    end

    # Named off where it came from until it is filed, because a list of
    # recordings all called `Transcript` is a list nobody can read. Once it is
    # on an interview the company names it.
    def title
      return @given[:title].to_s.strip if @given[:title].to_s.strip.present?

      [source["app"], source["host"]].compact_blank.first.presence || "Recorded call"
    end

    # A queue that is not there must not turn a recording that landed into one
    # that failed. The conversation is on the board either way.
    def start_reading(transcript)
      TranscriptSpeakersWorker.perform_async(transcript.id)
    rescue StandardError => e
      Rails.logger.warn("recording speakers enqueue failed: #{e.class}: #{e.message}")
    end
  end
end
