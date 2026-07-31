# UpsSmsParser.parse(text)
#
# Parses a forwarded UPS SMS notification into a carrier AmazonOrder. Handles the
# UPS text shapes:
#   "UPS: On the Way. ups.com/su/XXX Expect your NINGBO DEYI SAM package on
#    08/03/2026 by 9:00 PM. Reply STOP to cancel msgs"
#   "UPS: Delivered your NINGBO DEYI SAM package on 07/20/2026 at 5:35 PM."
#   "UPS: Delivery Update. … Expect your NINGBO DEYI SAM package on 07/20/2026
#    between 5:45 PM and 7:45 PM."
#   "UPS: 1Z16D56V0310080972 delivering tomorrow by 9:00 PM. Change Delivery: …"
#
# The per-message ups.com/su/… short links are per-notification, not per-package,
# so they're ignored — connection uses the tracking number (when present) or the
# sender name (best-effort) via Shipments::Connector.
class UpsSmsParser
  include ::Shipments::DateParsing

  TRACKING_REGEX = /\b1Z[0-9A-Z]{16}\b/
  SOURCE_REGEX = /\byour\s+(.+?)\s+package\b/i

  def self.parse(text, user: User.me)
    Time.use_zone(user.timezone) { new(text).parse }
  end

  def initialize(text)
    @text = text.to_s
  end

  def parse
    return false unless ::Shipments::SmsRouter.ups?(@text)

    item = ::Shipments::Connector.connect_or_create(
      carrier:         :ups,
      tracking_number: tracking_number,
      source:          source,
      name:            source,
    )

    item.source          ||= source
    item.tracking_number ||= tracking_number
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
    @text[TRACKING_REGEX]
  end

  def source
    @text[SOURCE_REGEX, 1]&.squish.presence
  end

  def delivered?
    @text.match?(/\bDelivered your\b/i)
  end

  def delivery_date
    slash_date_from(@text) ||
      (Time.zone.today + 1.day if @text.match?(/delivering\s+tomorrow/i)) ||
      (Time.zone.today if @text.match?(/delivering\s+today/i))
  end

  def time_range
    arrival_time_from(@text) || deadline_time_from(@text)
  end
end
