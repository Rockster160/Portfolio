# UspsEmailParser.parse(Email.find(<id>))
#
# Parses a forwarded USPS tracking email into a carrier AmazonOrder. Handles the
# "Expected Delivery" / "out for delivery" / "delivered" tracking notifications:
#   Subject: "USPS® Expected Delivery by Thursday, July 16, 2026 arriving by
#             9:00pm 9200190267338000065163052"
#   Body:    "Your item is out for delivery on July 16, 2026 at 7:18 am in
#             HERRIMAN, UT 84096. USPS expects to deliver your package today by
#             9:00pm. Tracking Number: 9200190267338000065163052.
#             Package Shipped from: SHOPIFY"
#
# The body "Tracking Number:" label is authoritative for the tracking number
# (the subject's trailing number is a fallback). Informed-Delivery "Daily Digest"
# / mailpiece emails carry no per-package tracking we care about and are skipped.
class UspsEmailParser
  include ::Shipments::DateParsing

  # USPS IMpb/tracking numbers are long digit runs, usually starting 92/94/93/95.
  TRACKING_LABEL_REGEX = /Tracking\s*Number\s*:?\s*([0-9]{18,})/i
  TRACKING_BARE_REGEX = /\b(9\d{17,25})\b/
  SOURCE_LABEL_REGEX = /Package\s+Shipped\s+from\s*:?\s*(.+)/im

  def self.parse(email)
    Time.use_zone(User.timezone) { new(email).parse }
  end

  def initialize(email)
    @email = email
    @doc = Nokogiri::HTML(@email.to_html)
  end

  def parse
    # Not a USPS tracking email we handle (digest / no tracking number) — leave
    # it for the Slack notifier, same as AmazonEmailParser's Jarvis-flag paths.
    return false if informed_delivery_digest?
    return false if tracking_number.blank?

    item = ::Shipments::Connector.connect_or_create(
      carrier:         :usps,
      tracking_number: tracking_number,
      source:          source,
      name:            source,
    )

    item.source          ||= source
    item.name            ||= source || tracking_number
    item.delivered = true if delivered?
    item.delivery_date = delivery_date if delivery_date.present?
    item.time_range = time_range if time_range.present?
    item.errors = []

    AmazonOrder.save
    AmazonOrder.broadcast
    item
  end

  def tracking_number
    body_text[TRACKING_LABEL_REGEX, 1] ||
      subject[TRACKING_BARE_REGEX, 1] ||
      body_text[TRACKING_BARE_REGEX, 1]
  end

  # The merchant is bolded right after "Package Shipped from:". Nokogiri's
  # whole-doc `.text` runs it straight into the next section (no block newlines),
  # so scope to the SMALLEST element that still contains the label — its own text
  # is just "Package Shipped from: SHOPIFY". Guard against an over-broad match.
  def source
    node = @doc.css("*").select { |n| n.text.match?(/Package\s+Shipped\s+from/i) }.min_by { |n| n.text.length }
    raw = node&.text&.[](SOURCE_LABEL_REGEX, 1)
    cleaned = raw&.squish
    return nil if cleaned.blank? || cleaned.length > 40

    cleaned
  end

  def delivered?
    body_text.match?(/\b(?:was|has been)\s+delivered\b|\bDelivered\b/i)
  end

  # USPS prints an explicit "Month Day, Year" — parse it directly (with the year)
  # rather than the year-less future() fallback so it stays accurate.
  def delivery_date
    combined = "#{subject} #{body_text}"
    if (m = combined.match(/(#{MONTH_REGEX}\s+\d{1,2},?\s+\d{4})/i))
      return (Date.parse(m[1]) rescue nil)
    end

    arrival_date_from(combined)
  end

  def time_range
    arrival_time_from(body_text) || deadline_time_from("#{subject} #{body_text}")
  end

  # Informed-Delivery digest ("Your Daily Digest … mailpiece(s) … package(s)")
  # is a summary, not a trackable shipment — skip it. Keyed on the digest subject
  # or "mailpiece" in the body; NOT on a bare "Informed Delivery" mention, which
  # also appears in the footer of ordinary USPS tracking emails.
  def informed_delivery_digest?
    subject.match?(/Daily\s+Digest/i) || body_text.match?(/mailpiece/i)
  end

  private

  def subject
    @email.subject.to_s
  end

  def body_text
    @body_text ||= @doc.text.to_s.gsub(/\s+/, " ").strip
  end
end
