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
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  # The chip is up for as long as the calls are running, so a pass that takes a
  # minute is something that can be SEEN happening rather than guessed at from
  # a page that has not changed yet. Keyed per transcript: two of them read at
  # once must not take each other's chip down.
  def perform(transcript_id)
    transcript = JobTranscript.find_by(id: transcript_id)
    return if transcript.nil?

    watched(transcript) { report(transcript, Transcripts::Speakers.call(transcript)) }
  end

  private

  def watched(transcript)
    BackgroundProcess.note(
      user:   transcript.job_application.user,
      key:    "transcript:speakers:#{transcript.id}",
      name:   "Reading the recording",
      detail: transcript.job_application.company,
      links:  [{ label: "📝", url: transcript_url(transcript) }],
      source: :rails,
    )
    yield
  ensure
    BackgroundProcess.clear(
      user: transcript.job_application.user,
      key:  "transcript:speakers:#{transcript.id}",
    )
  end

  def report(transcript, result)
    Rails.logger.info(
      "[TranscriptSpeakers] ##{transcript.id} #{result.ok ? "read" : "failed"} " \
      "placed=#{result.placed} unplaced=#{result.unplaced} error=#{result.error}",
    )
  end

  def transcript_url(transcript)
    "/interviews/#{transcript.job_application_id}/transcripts/#{transcript.id}"
  end
end
