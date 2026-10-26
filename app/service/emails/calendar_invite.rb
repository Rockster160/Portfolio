# frozen_string_literal: true

# The event inside a mail's calendar part: the invite a recruiter's calendar
# sends alongside the words, as a `text/calendar` part rather than a file.
#
# It is often the only place the time is written. A Calendly booking sent
# through Outlook carries a body of links and a LinkedIn URL, and the slot
# itself only in here - so anything reading the text alone sees an interview
# being arranged and never learns when it is.
class Emails::CalendarInvite
  # Outlook names zones the Windows way, which neither Rails nor tzinfo reads.
  # Anything not listed is tried as an IANA name, which is what everything else
  # sends.
  WINDOWS_ZONES = {
    "Eastern Standard Time"     => "America/New_York",
    "Central Standard Time"     => "America/Chicago",
    "Mountain Standard Time"    => "America/Denver",
    "US Mountain Standard Time" => "America/Phoenix",
    "Pacific Standard Time"     => "America/Los_Angeles",
    "Alaskan Standard Time"     => "America/Anchorage",
    "Hawaiian Standard Time"    => "Pacific/Honolulu",
    "GMT Standard Time"         => "Europe/London",
    "UTC"                       => "UTC",
  }.freeze

  STAMP = "%Y%m%dT%H%M%S"

  def self.from_parts(parts)
    part = Array(parts).find { |each| each.mime_type == "text/calendar" }
    part && parse(part.decoded)
  rescue StandardError => e
    Rails.logger.warn("[Emails::CalendarInvite] #{e.class}: #{e.message}")
    nil
  end

  # Nil unless the event has a time that can be placed. A start written with
  # no zone at all ("floating") or as a bare date is not an appointment
  # anybody could be on time for, and guessing a zone for it would book the
  # interview at the wrong hour.
  def self.parse(text)
    lines = unfold(text.to_s)
    method = lines.find { |line| line.start_with?("METHOD:") }.to_s.delete_prefix("METHOD:")
    fields = event_fields(lines)
    starts_at = time_of(fields["DTSTART"])
    return nil if starts_at.nil?

    {
      starts_at: starts_at,
      ends_at:   time_of(fields["DTEND"]),
      summary:   text_of(fields["SUMMARY"]),
      location:  text_of(fields["LOCATION"]),
      cancelled: method.casecmp?("CANCEL") || text_of(fields["STATUS"]).to_s.casecmp?("CANCELLED"),
    }
  end

  # A long line continues on the next one after a leading space or tab.
  def self.unfold(text)
    text.gsub(/\r\n?/, "\n").gsub(/\n[ \t]/, "").split("\n")
  end

  # The first of each property inside the VEVENT, as [params, value]. The time
  # zone blocks above it carry DTSTARTs of their own, for when a rule began.
  def self.event_fields(lines)
    inside = lines.drop_while { |line| line != "BEGIN:VEVENT" }.drop(1)
    inside.take_while { |line| line != "END:VEVENT" }.each_with_object({}) { |line, fields|
      head, value = line.split(":", 2)
      next if value.nil?

      name, *params = head.split(";")
      fields[name.upcase] ||= [params, value]
    }
  end

  def self.time_of(field)
    return nil if field.nil?

    params, value = field
    return ::Time.strptime("#{value.delete_suffix("Z")} UTC", "#{STAMP} %Z").utc if value.end_with?("Z")

    tzid = params.filter_map { |param| param.split("=", 2).last.delete('"') if param.start_with?("TZID=") }.first
    zone = tzid && ::ActiveSupport::TimeZone[WINDOWS_ZONES[tzid] || tzid]
    return nil if zone.nil? || !value.match?(/\A\d{8}T\d{6}\z/)

    zone.strptime(value, STAMP)
  end

  def self.text_of(field)
    return nil if field.nil?

    field.last.gsub(/\\([,;\\])/, '\1').gsub(/\\n/i, " ").strip.presence
  end
end
