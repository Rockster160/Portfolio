# THE LINK THAT IS A CALL YOU JOIN, found in whatever text carries it.
#
# Asked by three different things about three different kinds of text - the
# calendar part of an invite with no location on it, a beat typed against an
# application, the notes on an agenda row two minutes before it starts - which
# is why it does not live with any one of them. It used to sit in the interview
# heads-up, and a recurring standup's invite had no business asking an
# interview-prep module where to join.
module MeetingLink
  module_function

  # DELIBERATELY A LIST rather than "any URL". The text this is asked about is
  # full of links - the application page, a calendar's own "view event", a
  # reschedule page, a dial-in - and none of them is the one to tap when the
  # meeting has already started.
  HOSTS = [
    "meet.google.com",
    "zoom.us",
    "zoomgov.com",
    "teams.microsoft.com",
    "teams.microsoft.us",
    "teams.live.com",
    "webex.com",
    "whereby.com",
    "chime.aws",
    "meet.jit.si",
    "gotomeet.me",
    "meet.goto.com",
    "around.co",
    "hirevue.com",
    "coderpad.io",
    "codesignal.com",
    "hackerrank.com",
  ].freeze

  URL_RE = %r{https?://[^\s<>"')\]]+}

  def in(text)
    text.to_s.scan(URL_RE).find { |url| host?(url) }&.sub(/[.,;:!?]+\z/, "")
  end

  # A subdomain counts - `gov.teams.microsoft.us` is the government tenant of a
  # listed host, and the first Teams invite on file was on one.
  def host?(url)
    host = ::URI.parse(url).host.to_s.downcase
    HOSTS.any? { |known| host == known || host.end_with?(".#{known}") }
  rescue ::URI::InvalidURIError
    false
  end
end
