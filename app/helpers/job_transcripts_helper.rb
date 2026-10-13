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

  # The side of the conversation a turn sits on. Three, not two: his own, the
  # people he was talking to, and the ones nobody has placed — which are worth
  # looking different, because they are the ones to go and correct.
  def transcript_side(transcript, turn)
    label = turn["speaker"].to_s
    return "unplaced" if label == JobTranscript::UNKNOWN || transcript.name_for(label) == label
    return "mine" if transcript.mine?(label)

    "theirs"
  end
end
