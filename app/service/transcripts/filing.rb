module Transcripts
  # Which interview a recording was, worked out from the clock.
  #
  # NOTHING ARMS OFF THE CALENDAR. The recorder starts when the microphone goes
  # hot and knows nothing about the board, which is deliberate: a booking can be
  # an hour out, moved by a mail nobody read, or never written down at all, and
  # a recorder that trusted it would miss the interview. So the booking is never
  # asked whether a call is happening - it is only asked, afterwards, which call
  # this was.
  #
  # ONE CANDIDATE OR NONE. Two interviews in an afternoon with overlapping
  # windows is exactly when a guess is expensive: a debrief filed on the wrong
  # company reads as a conversation he never had, and he would have no reason
  # to doubt it. So anything short of a single answer leaves the recording
  # unfiled, where the index asks him - and it asks with the candidates it
  # found rather than a blank picker.
  #
  # FILING BY HAND IS FINAL. A booking mail arriving the next morning never
  # moves a recording somebody has already placed.
  module Filing
    module_function

    # The bookings a recording can belong to: the two beats that mean a
    # conversation happened. An `applied` or a `rejected` row is a mail, and
    # nothing was said out loud on it.
    TAGS = JobNote::CONVERSATIONS

    # How far from a booking's start a recording may begin and still be it.
    # Asymmetric, because the two directions are different stories: starting
    # early is joining the call early, and it is never by much. Starting late
    # is the round before it running over, which happens by a lot.
    EARLY = 15.minutes
    LATE = 45.minutes

    # What a booking that never said how long it was is assumed to run, so an
    # overlap can be worked out at all.
    DEFAULT_MINUTES = JobNote::DEFAULT_INTERVIEW_MINUTES

    # The window a booking is looked for in. Wider than EARLY/LATE on purpose:
    # the query is cheap and coarse, and the two tests below are what actually
    # decide it.
    REACH = 6.hours

    # Files the recording if there is exactly one answer, and says which. Nil
    # for every other case, including a recording somebody already placed -
    # this is the automatic pass, and it never overrules a person.
    def call(transcript)
      return nil if transcript.filed?

      found = candidates(transcript)
      return nil unless found.one?

      note = found.first
      transcript.file!(note.job_application, note: note)
      note
    end

    # Every booking this recording could be, best first. Read by the index as
    # well as by the filing, which is what makes the question on the page
    # "Podium or Brightwheel?" rather than a search box.
    def candidates(transcript)
      started = transcript.occurred_at
      owner = transcript.owner
      return [] if started.nil? || owner.nil?

      near(owner, started).select { |note|
        overlaps?(transcript, note) || close?(started, note)
      }.sort_by { |note| (note.occurred_at - started).abs }
    end

    # The bookings anywhere near it, in one query. Loaded with their
    # applications because the caller names the company for every one of them.
    def near(user, started)
      JobNote.where(
        tag:                TAGS,
        occurred_at:        (started - REACH)..(started + REACH),
        job_application_id: user.job_applications.select(:id),
      ).includes(:job_application).to_a
    end

    # Did the two actually run at the same time? This is the test that gets the
    # hour-long round he joined ten minutes late, which a nearest-start rule
    # reads as belonging to whatever was booked for half past.
    def overlaps?(transcript, note)
      spoken = span(transcript)
      booked = note.occurred_at..(note.occurred_at + minutes(note))

      spoken.begin < booked.end && booked.begin < spoken.end
    end

    def close?(started, note)
      started.between?(note.occurred_at - EARLY, note.occurred_at + LATE)
    end

    # The recording's own span. A recording with no length to it is treated as
    # the instant it started, which leaves `close?` to answer for it.
    def span(transcript)
      started = transcript.occurred_at
      minutes = transcript.spoken_minutes.to_i
      started..(started + minutes.minutes)
    end

    def minutes(note)
      (note.duration_minutes.presence || DEFAULT_MINUTES).minutes
    end
  end
end
