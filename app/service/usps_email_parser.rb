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
# (the subject's trailing number is a fallback).
#
# Informed-Delivery "Daily Digest" emails are ALSO parsed: their Packages section
# lists each inbound package as "FROM: <sender> <tracking>" under date buckets
# ("Expected Today" / "Expected 1-2 Days"). Mailpieces (letter scans) carry no
# tracking number, so requiring one naturally skips them. Digests matter because
# the full per-package tracking email doesn't always arrive.
class UspsEmailParser
  include ::Shipments::DateParsing

  # USPS IMpb/tracking numbers are long digit runs, usually starting 92/94/93/95.
  TRACKING_LABEL_REGEX = /Tracking\s*Number\s*:?\s*([0-9]{18,})/i
  TRACKING_BARE_REGEX = /\b(9\d{17,25})\b/
  SOURCE_LABEL_REGEX = /Package\s+Shipped\s+from\s*:?\s*(.+)/im

  # Digest package row: "FROM: SHOPIFY 9200190267338000065163052". Nokogiri's
  # `.text` concatenates the bolded merchant straight onto the tracking number
  # with no space ("SHOPIFY92001902…"), so the separator is optional and the
  # tracking's leading 9 + 16 digits is the real boundary. Source is bounded
  # (letters/digits/space/punct, ≤38 chars) so a lazy match can't span from the
  # forwarded "From: USPS Informed Delivery <…>" header to a later tracking.
  DIGEST_PKG_REGEX = /FROM:\s*([A-Z0-9][A-Z0-9 .&'-]{0,38}?)\s*(9\d{15,})/i
  DIGEST_BUCKET_REGEX = /Expected Today|Expected 1-2 Days|Awaiting From Sender|Outbound/i

  def self.parse(email)
    Time.use_zone(User.timezone) { new(email).parse }
  end

  def initialize(email)
    @email = email
    @doc = Nokogiri::HTML(@email.to_html)
  end

  def parse
    return parse_digest if informed_delivery_digest?
    return false if tracking_number.blank? # not a USPS email we handle → Slack fallback

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
    item.email_ids << @email.id unless item.email_ids.include?(@email.id)

    AmazonOrder.save
    AmazonOrder.broadcast
    item
  end

  # Informed-Delivery digest: create/connect an item per package in the Packages
  # section (skipping mailpieces, which have no tracking). Returns the items (so
  # the worker archives), or nil when no package was found → Slack fallback.
  def parse_digest
    packages = digest_packages
    return if packages.empty?

    items = packages.map { |pkg|
      item = ::Shipments::Connector.connect_or_create(
        carrier:         :usps,
        tracking_number: pkg[:tracking],
        source:          pkg[:source],
        name:            pkg[:source],
      )
      item.source ||= pkg[:source]
      item.name   ||= pkg[:source] || pkg[:tracking]
      # Digest dates are coarse — don't overwrite a precise date a full tracking
      # email already set. Only fill when we still have nothing.
      item.delivery_date = pkg[:date] if pkg[:date].present? && item.delivery_date.blank?
      item.errors = []
      item.email_ids << @email.id unless item.email_ids.include?(@email.id)
      item
    }

    AmazonOrder.save
    AmazonOrder.broadcast
    items
  end

  # Splits the digest text on bucket labels so each package inherits its bucket's
  # rough delivery date. Skips the "Outbound" bucket (packages you're sending).
  def digest_packages
    segments = body_text.split(/(#{DIGEST_BUCKET_REGEX})/)
    packages = {}
    segments.each_with_index { |seg, i|
      next unless seg.match?(/\A#{DIGEST_BUCKET_REGEX}\z/)

      label = seg.downcase
      next if label == "outbound"

      date = digest_bucket_date(label)
      segments[i + 1].to_s.scan(DIGEST_PKG_REGEX) { |src, tracking|
        packages[tracking] ||= { source: src.squish.presence, tracking: tracking, date: date }
      }
    }
    packages.values
  end

  def digest_bucket_date(label)
    case label
    when "expected today"     then Time.zone.today
    when "expected 1-2 days"  then Time.zone.today + 1.day
    end
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

  # Routes to the digest parser. Keyed on the digest subject or "mailpiece" in
  # the body; NOT on a bare "Informed Delivery" mention, which also appears in
  # the footer of ordinary USPS tracking emails.
  def informed_delivery_digest?
    subject.match?(/Daily\s+Digest/i) || body_text.match?(/mailpiece/i)
  end

  private

  def subject
    @email.subject.to_s
  end

  # Normalize with POSIX [[:space:]] (not \s) so non-breaking spaces — which USPS
  # sprinkles between the merchant and tracking number — collapse to real spaces.
  def body_text
    @body_text ||= @doc.text.to_s.gsub(/[[:space:]]+/, " ").strip
  end
end
