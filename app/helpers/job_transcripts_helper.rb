# Reading a transcript on the page.
module JobTranscriptsHelper
  # The time against a turn, which is either a clock reading or an offset
  # depending on the recorder: one writes `11:59:55` and means noon, the other
  # writes `00:04:12` and means four minutes in. Both are the same number of
  # seconds, and both read correctly as a time — so this formats and does not
  # try to decide which one it is holding.
  #
  # The leading `0:` goes, because an hour that is zero is not information.
  def transcript_clock(seconds)
    return nil if seconds.blank?

    whole = seconds.to_i
    said = format(
      "%<h>d:%<m>02d:%<s>02d",
      h: whole / 3600, m: (whole % 3600) / 60, s: whole % 60,
    )
    said.sub(/\A0:/, "")
  end

  # What the pass is doing, while it is doing it. The count only appears once
  # the first call has come back, because until then how many there will be is
  # not known - and "1 of 1" invented for the wait before the first answer
  # would be wrong on every transcript that takes more than one call.
  def transcript_reading(transcript)
    reading = transcript.reading
    return nil if reading.nil?

    moved = (" — pass #{reading.current} of #{reading.total}" if reading.current && reading.total)
    "Working out who was talking#{moved}."
  end

  # The side of the conversation a turn sits on. Three, not two: his own, the
  # people he was talking to, and the ones nobody has placed — which are worth
  # looking different, because they are the ones to go and correct.
  # Placed is "somebody said so", not "it has a name on it". A split into sides
  # writes `Them`, which IS the answer to who was speaking and reads as its own
  # name - tested on the name alone it came out as the one thing it is not,
  # a turn nobody has got to yet.
  def transcript_side(transcript, turn)
    label = turn["speaker"].to_s
    return "unplaced" if label == JobTranscript::UNKNOWN
    return "mine" if transcript.mine?(label)
    return "theirs" if transcript.speakers[label].present?

    "unplaced"
  end
end
