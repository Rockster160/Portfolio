module Transcripts
  # A recording arriving on an application: a file picked or dropped, or the
  # words pasted straight in.
  #
  # PASTED TEXT IS A FILE. Voice Memos hands the whole recording over as one
  # unbroken line and offers nowhere to save it, so the only way to upload it
  # was to open a text editor, paste it there, save it, and come back for the
  # file. The paste is written as the `.txt` it would have been and read by the
  # same parser - nothing past this point knows which way it came in, and the
  # words are still kept as a file for the rereading the parse sometimes needs.
  #
  # Both ways in run through here because there are two doors: the panel on the
  # application, and the beat form, where a conversation and the note saying it
  # happened get logged in one submit.
  class Intake
    PASTED = "pasted-transcript.txt".freeze
    TEXT = "text/plain".freeze

    def self.call(job, given, note: nil) = new(job, given, note: note).call

    def initialize(job, given, note: nil)
      @job = job
      @given = open_hash(given)
      @note = note
    end

    # The transcript, or nil when nothing was handed over - which is every
    # ordinary note, so it is an answer rather than an error.
    def call
      return nil if upload.blank? && pasted.blank?

      words = read
      transcript = @job.transcripts.new(title: @given[:title].presence, job_note_id: note_id)
      transcript.ingest!(words, filename: upload&.original_filename)
      transcript.file.attach(io: StringIO.new(words), filename: blob_name, content_type: type)
      transcript.save!
      start_reading(transcript)
      transcript
    end

    private

    def upload
      @given[:file].presence
    end

    def pasted
      @given[:text].to_s.strip.presence
    end

    # The beat this belongs to. The note the submit created wins over the
    # picker: a form that logged the conversation and the note together was
    # never offered the picker in the first place.
    def note_id
      @note&.id || @given[:job_note_id].presence
    end

    # Read ONCE, into a string, because the parse and the kept file both want
    # the whole of it. An IO read to the end attaches as an empty file, and the
    # upload would be on the page, nameable and readable, with nothing behind
    # the download link.
    def read
      return pasted if upload.blank?

      io = upload.respond_to?(:tempfile) ? upload.tempfile : upload
      io.rewind if io.respond_to?(:rewind)
      io.read.to_s
    end

    def blob_name
      upload&.original_filename.presence || PASTED
    end

    def type
      upload&.content_type.presence || TEXT
    end

    # An upload that landed is an upload that landed. A queue that is not there
    # must not turn it into "that could not be read" - the conversation is on
    # the page either way, and who was talking is the part that is missing.
    def start_reading(transcript)
      TranscriptSpeakersWorker.perform_async(transcript.id)
    rescue StandardError => e
      Rails.logger.warn("transcript speakers enqueue failed: #{e.class}: #{e.message}")
    end

    def open_hash(given)
      return {} if given.blank?
      return given.to_unsafe_h.symbolize_keys if given.respond_to?(:to_unsafe_h)

      given.to_h.symbolize_keys
    end
  end
end
