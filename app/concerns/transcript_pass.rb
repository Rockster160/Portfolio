# The chip a pass over a recording runs under.
#
# Both passes - who was talking, and what they actually said - are several
# model calls over half an hour of text, and the only thing that distinguishes
# one running from one that could make nothing of the file is a chip saying so.
# Shared rather than written twice because the pair of them read as one job
# from the outside: something is being worked out about the recording, and the
# count is how far along it is.
#
# Keyed per pass per transcript, which is what keeps two of them in flight at
# once - or two transcripts read at the same time - from taking each other's
# chip down.
module TranscriptPass
  extend ActiveSupport::Concern

  private

  # The chip goes up BEFORE the first call, because the first call is the
  # longest wait and a chip that appears once something finished says the
  # opposite of what it is for. Every call after it moves the count, which is
  # the difference between working and hung, visible without opening a log.
  def watched(transcript, key:, name:)
    note(transcript, key, name)
    yield(->(done, total) { note(transcript, key, name, current: done, total: total) })
  ensure
    BackgroundProcess.clear(user: transcript.owner, key: key)
  end

  def note(transcript, key, name, **moved)
    BackgroundProcess.note(
      user:   transcript.owner,
      key:    key,
      name:   name,
      detail: transcript.job_application&.company || transcript.source_label,
      links:  [{ label: "📝", url: transcript_url(transcript) }],
      source: :rails,
      **moved,
    )
  end

  # A recording nobody has filed has no page of its own: what there is to do
  # with it is on the interview index, which is where the panel asking about it
  # lives.
  def transcript_url(transcript)
    return "/interviews" unless transcript.filed?

    "/interviews/#{transcript.job_application_id}/transcripts/#{transcript.id}"
  end
end
