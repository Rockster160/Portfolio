# Works out who was talking, once, on every transcript that lands.
#
# Queued by the upload itself rather than by anything he presses: dropping the
# file in is the whole instruction, and what the file needs - a split into
# sides, or being told which of its labels is him - is `Transcripts::Speakers`
# reading the file rather than a question for whoever uploaded it.
#
# Out here rather than inline for the reason every other model call in this
# codebase is: half an hour of talking is several calls, and an upload must not
# sit there waiting for them. `low` queue because nothing is blocked on the
# answer and a backlog of these must never delay a reminder firing.
#
# Takes an id rather than a record so a retry re-reads current state, and gives
# up quietly on anything since deleted - or on a transcript whose speakers were
# settled in the meantime, which `Speakers.call` refuses.
class TranscriptSpeakersWorker
  include Sidekiq::Worker, TranscriptPass

  sidekiq_options queue: :low, retry: 1

  NAME = "Reading the recording".freeze

  # The chip is up for as long as the calls are running, so a pass that takes a
  # minute is something that can be SEEN happening rather than guessed at from
  # a page that has not changed yet.
  #
  # The words themselves are gone over for mishearings straight afterwards and
  # not in here. That pass reads the turns THIS one writes - a wall of text has
  # to be cut into turns before there is anything to read word by word - and
  # the two under one chip would be one count over two jobs of different
  # lengths.
  def perform(transcript_id)
    transcript = JobTranscript.find_by(id: transcript_id)
    return if transcript.nil?

    watched(transcript, key: Transcripts::Speakers.key_for(transcript), name: NAME) { |progress|
      report(transcript, Transcripts::Speakers.call(transcript, &progress))
    }
    queue_tidy(transcript)
  end

  private

  # A queue that is not there must not turn a finished reading into a failed
  # one. The conversation is on the page either way, and the words in it stay
  # whatever the recorder heard until this runs.
  def queue_tidy(transcript)
    TranscriptTidyWorker.perform_async(transcript.id)
  rescue StandardError => e
    Rails.logger.warn("transcript tidy enqueue failed: #{e.class}: #{e.message}")
  end

  def report(transcript, result)
    Rails.logger.info(
      "[TranscriptSpeakers] ##{transcript.id} #{result.ok ? "read" : "failed"} " \
      "placed=#{result.placed} unplaced=#{result.unplaced} error=#{result.error}",
    )
  end
end
