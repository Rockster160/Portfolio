# Dates on the interview tracker. Everything here is either an appointment or
# something owed by a date, so it's read to plan around — which means the
# weekday is the part that matters. "Sep 7" needs a calendar lookup before it
# means anything; "Monday, Sep 7" is already the answer.
module JobApplicationsHelper
  def interview_day(time, at_time: true)
    return nil if time.blank?

    time.strftime(at_time ? "%A, %b %-d at %-I:%M %p" : "%A, %b %-d")
  end

  # A note body, verbatim, with its links clickable.
  #
  # The body is printed as typed rather than through `simple_format` — the
  # indentation somebody used to hang sub-notes under a line is part of what
  # they wrote — and that is still true here. This turns two things into
  # anchors and changes nothing else:
  #
  #   [what was sent](https://…)   a markdown link, the same shape Byte accepts
  #   https://…                    a bare URL, because every note written
  #                                before this one has them
  #
  # A URL that is not plainly http(s) is left exactly as it was written. The
  # local job hunter puts `http://localhost:8790/...` in these, which is the
  # link most worth having and the kind a stricter check would throw away.
  MD_LINK  = /\[([^\]\n]+)\]\(([^)\s]+)\)/
  BARE_URL = %r{\bhttps?://[^\s<>"'\]]+}
  SAFE_URL = %r{\Ahttps?://[^\s<>"']+\z}i

  # Sentence punctuation that a URL at the end of a sentence collects and does
  # not own. "at https://x.test/a, then" links `…/a`, not `…/a,`.
  TRAILING = /[.,;:!?)\]]+\z/

  def note_body(text)
    rest = text.to_s
    out = +""

    while (hit = MD_LINK.match(rest))
      out << autolink(hit.pre_match)
      out << note_link(hit[2], hit[1], instead: hit[0])
      rest = hit.post_match
    end
    out << autolink(rest)

    out.html_safe # rubocop:disable Rails/OutputSafety -- every branch escapes
  end

  private

  # Escapes as it goes rather than escaping the whole chunk first, so nothing is
  # ever escaped twice: the anchors this builds would come back out as text, and
  # an `&` inside a URL would become `&amp;amp;`.
  def autolink(chunk)
    rest = chunk.to_s
    out = +""

    while (hit = BARE_URL.match(rest))
      out << ERB::Util.html_escape(hit.pre_match)
      url = hit[0]
      link = url.sub(TRAILING, "")
      out << note_link(link, link)
      out << ERB::Util.html_escape(url[link.length..].to_s)
      rest = hit.post_match
    end

    out << ERB::Util.html_escape(rest)
    out
  end

  # `instead` is what to show when the link is refused — the markdown as it was
  # typed, so a note never quietly loses the thing it was pointing at.
  def note_link(url, label, instead: nil)
    return ERB::Util.html_escape(instead || label).to_s unless url.to_s.match?(SAFE_URL)

    %(<a href="#{ERB::Util.html_escape(url)}" target="_blank" rel="noopener">#{ERB::Util.html_escape(label)}</a>)
  end
end
