# Google event descriptions arrive as HTML — rich text in the Calendar UI
# is preserved with tags + entities. We render plain text in the agenda, so
# we strip tags + unescape entities at the ingest boundary.
module GoogleCalendar::HtmlText
  SANITIZER = ::ActionView::Base.full_sanitizer

  # Strip tags + decode entities + normalize trailing whitespace.
  # Returns nil unchanged so AR doesn't write empty strings where Google
  # actually omitted the field.
  def self.to_plain(html)
    return nil if html.nil?

    text = SANITIZER.sanitize(html.to_s)
    decoded = ::CGI.unescapeHTML(text)
    decoded.gsub(/[ \t]+\n/, "\n").strip.presence
  end
end
