# Writes a readable version of the conversation beside the spoken one, once on
# every transcript that lands - and again on the one being read when he asks
# for it.
#
# Queued by the pass over the words rather than by the upload, because it
# cleans what that pass leaves behind: a turn whose misheard words have been
# put right cleans into a sentence that says the right thing, and one cleaned
# first has the mishearing smoothed into it and reads as deliberate.
#
# RUNS BESIDE THE READ OF HOW IT WENT, NOT BEFORE IT. The two are independent
# readings of the same words and neither wants the other's output: the debrief
# judges how he actually talked, and cleaned text is the hedging and circling
# it is looking for already taken out. So the words pass hands on to both, and
# a failure in either leaves the other alone.
#
# Takes an id rather than a record so a retry re-reads current state, and gives
# up quietly on anything since deleted. `again` is the press on the page:
# `Clean.call` refuses a transcript it has already done unless it is asked
# twice.
class TranscriptCleanWorker
  include Sidekiq::Worker, TranscriptPass

  sidekiq_options queue: :low, retry: 1

  NAME = "Cleaning it up".freeze

  def perform(transcript_id, again=false)
    transcript = JobTranscript.find_by(id: transcript_id)
    return if transcript.nil?

    watched(transcript, key: Transcripts::Clean.key_for(transcript), name: NAME) { |progress|
      report(transcript, Transcripts::Clean.call(transcript, again: again, &progress))
    }
    # The recording is ready to read when every pass has been over it, and
    # the two that run beside each other have no way of knowing which of them
    # is last. So both ask, and the claim inside `Announce` is what makes it
    # one message.
    Transcripts::Announce.call(transcript.reload)
  end

  private

  def report(transcript, result)
    Rails.logger.info(
      "[TranscriptClean] ##{transcript.id} #{result.ok ? "cleaned" : "skipped"} " \
      "written=#{result.cleaned} turns=#{result.turns} error=#{result.error}",
    )
  end
end
