# WayfairSmsParser.parse(text)
#
# Parses a forwarded Wayfair SMS notification into a carrier AmazonOrder:
#   "Wayfair: Exciting news! Your order is out for delivery. Track your desk
#    here: https://www.wayfair.com/pXJxCqyzBM"
#
# Wayfair is a merchant, not a carrier — its texts never carry the underlying
# carrier's tracking number, only a per-order short link. So the link is kept
# as the item's `custom_url` (what the dashboard opens) and the PRODUCT name
# ("Track your desk here" -> "desk") is what connects one text to the next.
# Every Wayfair text says "Wayfair", so the source can't tell two orders apart.
class WayfairSmsParser
  include ::Shipments::DateParsing

  SOURCE = "Wayfair".freeze
  URL_REGEX = %r{https?://\S*wayfair\.com/\S+}i
  NAME_REGEX = /\btrack\s+your\s+(.+?)\s+here\b/i
  STATUS_NAME_REGEX = /\byour\s+(.+?)\s+(?:is|was|has been|have been)\s+(?:out for delivery|delivered|on its way|shipped)\b/i
  # What Wayfair calls a thing when it isn't naming the product. Connecting on
  # "order" would fold every unrelated Wayfair shipment into one row.
  GENERIC_NAMES = %w[order orders package packages item items shipment delivery].freeze

  def self.parse(text, user: User.me)
    Time.use_zone(user.timezone) { new(text).parse }
  end

  def initialize(text)
    @text = text.to_s
  end

  def parse
    return false unless ::Shipments::SmsRouter.wayfair?(@text)

    item = ::Shipments::Connector.connect_or_create(
      carrier:    :wayfair,
      source:     SOURCE,
      name:       name,
      connect_on: name.present? ? :name : :source,
    )

    item.source ||= SOURCE
    item.name   ||= name || SOURCE
    # Each text carries a fresh short link; the newest is the one that resolves.
    item.custom_url = url if url.present?
    item.delivered = true if delivered?
    item.delivery_date = delivery_date if delivery_date.present?
    item.time_range = time_range if time_range.present?
    item.errors = []

    AmazonOrder.save
    AmazonOrder.broadcast
    item
  end

  def name
    product = @text[NAME_REGEX, 1] || @text[STATUS_NAME_REGEX, 1]
    product = product&.squish.presence
    return nil if product.nil? || GENERIC_NAMES.include?(product.downcase)

    product
  end

  def url
    @text[URL_REGEX]&.sub(/[.,;:)\]]+\z/, "").presence
  end

  def delivered?
    @text.match?(/\bdelivered\b/i)
  end

  def delivery_date
    return Time.zone.today if @text.match?(/\bout for delivery\b/i)

    slash_date_from(datetext) || arrival_date_from(datetext) ||
      (Time.zone.today if delivered?)
  end

  def time_range
    arrival_time_from(datetext) || deadline_time_from(datetext)
  end

  private

  # The short link is opaque — its path can hold anything, including something
  # that reads as a date to the shared parsers. Dates come from the prose only.
  def datetext
    @datetext ||= @text.gsub(URL_REGEX, " ")
  end
end
