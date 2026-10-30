# Reads a recorded interview for how it went, once, on every transcript that
# lands - and again on the one being read when he asks for it.
#
# Queued by the words pass rather than by the upload, because it is the last of
# three and each one reads what the one before it wrote: a debrief of a
# conversation whose speakers are unsplit does not know which half is his, and
# one written off unmended words is feedback on sentences he did not say.
#
# Takes an id rather than a record so a retry re-reads current state, and gives
# up quietly on anything since deleted. `again` is the press on the page, and
# it also arrives from a second pass over the words - the words it would be
# reading have just changed, so the reading of them is worth doing over.
class TranscriptDebriefWorker
  include Sidekiq::Worker, TranscriptPass

  sidekiq_options queue: :low, retry: 1

  NAME = "Reading how it went".freeze

  def perform(transcript_id, again=false)
    transcript = JobTranscript.find_by(id: transcript_id)
    return if transcript.nil?

    watched(transcript, key: Transcripts::Debrief.key_for(transcript), name: NAME) { |progress|
      report(transcript, Transcripts::Debrief.call(transcript, again: again, &progress))
    }
  end

  private

  def report(transcript, result)
    Rails.logger.info(
      "[TranscriptDebrief] ##{transcript.id} #{result.ok ? "read" : "skipped"} " \
      "notes=#{result.notes} error=#{result.error}",
    )
  end
end
