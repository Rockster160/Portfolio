module Transcripts
  # The one message that says a recording is ready to read.
  #
  # Four passes run over a recording and the last two run beside each other, so
  # there is no single worker that finishing means the job is done. The chip on
  # the strip says a pass is in flight and goes when it ends, which answers "is
  # anything happening" and not "can I read this now" - and the whole point of
  # the recording is the second question. So the stamps are what is read here,
  # and whichever of the two finishes last is the one that speaks.
  #
  # EXACTLY ONCE, claimed in the database rather than worked out in Ruby. Both
  # passes can land in the same instant on two Sidekiq threads, and both would
  # then see a finished transcript and both would send. The claim is an UPDATE
  # guarded on the stamp being null, so one of them writes a row and the other
  # writes none and says nothing.
  #
  # A pass that came back unusable never stamps, so a recording the cleaning
  # could make nothing of is not announced. That is deliberate: the message
  # says it is ready to read, and half of it is missing.
  module Announce
    module_function

    SOURCE = "transcript_ready".freeze

    # Ready to be read and nowhere to say so - a thread with no live Buddy
    # conversation in it. Raised rather than returned, so it goes back through
    # the one path that puts the claim back.
    Untellable = Class.new(StandardError)

    def call(transcript)
      return false unless ready?(transcript)
      return false unless claimed?(transcript)

      target = thread(transcript)
      raise(Untellable, "no thread to send it to") if target.nil?

      send!(transcript, target)
      true
    rescue StandardError => e
      # THE CLAIM GOES BACK. It was taken before the send so two passes landing
      # together could not both speak, which means holding it after a failure
      # would mark him as told about a message that never arrived - and nothing
      # would ever try again.
      release(transcript)
      Rails.logger.warn("[TranscriptAnnounce] ##{transcript.id} not told: #{e.class}: #{e.message}")
      false
    end

    # Every pass that writes something a reader uses has been over it. The
    # split is not among them: a recording nobody could be placed on is still
    # one worth reading, and the words pass runs on whatever the split made of
    # the file.
    def ready?(transcript)
      transcript.tidied_at.present? &&
        transcript.debriefed_at.present? &&
        transcript.cleaned_at.present?
    end

    # Whoever gets the row gets to send. `update_all` rather than `update!` so
    # the guard and the write are one statement and no callback can reorder
    # them.
    def claimed?(transcript)
      # rubocop:disable Rails/SkipsModelValidations -- the guard and the write
      # have to be one statement; a load, a check and a save is the race.
      claimed = JobTranscript.where(id: transcript.id, announced_at: nil).update_all(
        announced_at: Time.current,
        updated_at:   Time.current,
      )
      # rubocop:enable Rails/SkipsModelValidations
      claimed == 1
    end

    def release(transcript)
      JobTranscript.where(id: transcript.id).update_all(announced_at: nil) # rubocop:disable Rails/SkipsModelValidations
    end

    def thread(transcript)
      owner = transcript.owner
      return nil if owner.nil?

      ByteConversation.for_self_initiated(owner)
    end

    # THE CLEANED READ, not the spoken one. The page opens on the words as they
    # were said because that is the version his corrections are made against,
    # but this message exists because the cleaning just finished - following it
    # to the spoken read would be answering a different sentence. The switch
    # back is one tap and it is in the URL either way.
    def send!(transcript, target)
      Buddy::CompanionDelivery.deliver_plain(
        user:         transcript.owner,
        conversation: target,
        text:         "#{said(transcript)}\n\n#{transcript.reading_url(read: :clean)}",
        metadata:     { "kind" => "buddy", "source" => SOURCE, "transcript_id" => transcript.id },
        push_title:   push_title(transcript),
      )
    end

    # What it was, then what was done to it, then the numbers - because the
    # numbers are the difference between "it ran" and "it found something", and
    # they are the reason to open it now rather than later.
    def said(transcript)
      "#{label(transcript)} is read and cleaned up. #{counted(transcript)}"
    end

    def counted(transcript)
      [
        "#{transcript.turns.size} turns",
        "#{transcript.mended} put right",
        "#{transcript.cleaned} cleaned",
        "#{transcript.noted} notes on how it went",
      ].join(", ")
    end

    # The company if it has been filed, and otherwise whatever the recorder
    # called itself - an unfiled recording has no interview to name, and "a
    # recording" tells him nothing about which one.
    def label(transcript)
      [
        transcript.job_application&.company,
        transcript.title.presence,
      ].compact_blank.first || transcript.source_label || "A recording"
    end

    def push_title(transcript)
      "#{label(transcript)} transcript"
    end
  end
end
