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

  # What a pass is doing, while it is doing it. The count only appears once the
  # first call has come back, because until then how many there will be is not
  # known - and "1 of 1" invented for the wait before the first answer would be
  # wrong on every transcript that takes more than one call.
  def transcript_reading(transcript)
    pass_said("Working out who was talking", transcript.reading)
  end

  def transcript_tidying(transcript)
    pass_said("Checking what was actually said", transcript.tidying)
  end

  def transcript_debriefing(transcript)
    pass_said("Reading how the conversation went", transcript.debriefing)
  end

  # The line a note in the debrief is about, quoted. Cut short on purpose: the
  # note is the point and the whole turn is on the page below, linked - a note
  # carrying four hundred words of what he said is the answer printed twice.
  def debrief_quote(transcript, number, limit: 240)
    turn = transcript.said_at(number)
    return nil if turn.nil?

    turn["text"].to_s.truncate(limit)
  end

  # Where to jump to. The turns carry these ids, so a note about minute
  # thirty-four opens the sentence it is about rather than describing it.
  def debrief_anchor(number)
    "#t#{number.to_i}"
  end

  def debrief_at(transcript, number)
    turn = transcript.said_at(number)
    return nil if turn.nil?

    transcript_clock(turn["at"]).presence || "turn #{number.to_i}"
  end

  # What was put right, once a pass has been over the words. Said as a count
  # rather than a tick, because the two facts a reader wants are different
  # ones: that the recording has been gone over at all, and whether it needed
  # much doing to it.
  def transcript_mended(transcript)
    return nil if transcript.tidied_at.nil?

    mended = transcript.mended
    return "words checked" if mended.zero?

    "#{pluralize(mended, "turn")} put right"
  end

  # What the recorder wrote, on a turn whose words were put right. Nothing at
  # all on the rest, so the attribute is absent rather than empty - an empty
  # title on every turn of a transcript is a tooltip that opens on nothing.
  def heard_title(turn)
    return nil if turn["heard"].blank?

    "As the recorder heard it: #{turn["heard"]}"
  end

  def pass_said(said, pass)
    return nil if pass.nil?

    moved = (" — pass #{pass.current} of #{pass.total}" if pass.current && pass.total)
    "#{said}#{moved}."
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
