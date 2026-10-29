# Puts right the words the recorder misheard, once, on every transcript that
# lands - and again on the one being read when he asks for it.
#
# Queued by the split pass rather than by the upload, because it runs on the
# turns that pass writes: a wall of text is cut into turns by `Speakers`, and a
# tidy before that would fix words in a wall that is then thrown away and
# rebuilt. It runs whatever the split pass made of the file - a transcript
# nobody could be placed on is still a transcript worth being able to read.
#
# Takes an id rather than a record so a retry re-reads current state, and gives
# up quietly on anything since deleted. `again` is the press on the page:
# `Tidy.call` refuses a transcript it has already been over unless it is asked
# twice, so the words are gone over once by itself and after that on request.
class TranscriptTidyWorker
  include Sidekiq::Worker, TranscriptPass

  sidekiq_options queue: :low, retry: 1

  NAME = "Fixing the words".freeze

  def perform(transcript_id, again=false)
    transcript = JobTranscript.find_by(id: transcript_id)
    return if transcript.nil?

    watched(transcript, key: Transcripts::Tidy.key_for(transcript), name: NAME) { |progress|
      report(transcript, Transcripts::Tidy.call(transcript, again: again, &progress))
    }
  end

  private

  def report(transcript, result)
    Rails.logger.info(
      "[TranscriptTidy] ##{transcript.id} #{result.ok ? "read" : "skipped"} " \
      "mended=#{result.mended} turns=#{result.turns} error=#{result.error}",
    )
  end
end
