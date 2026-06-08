# AmazonEmailParser.parse(Email.find(<id>))
#
# Parses the modern Amazon shipment email format (rio-card / rexMultiOrderCard).
# Each shipment email - ordered, shipped, delayed, out for delivery, or delivered -
# finds-or-creates an AmazonOrder per item (ASIN) on the order, updates the expected
# delivery date, and flips `delivered` true when the email reports the package as delivered.
class AmazonEmailParserError < StandardError; end

class AmazonEmailParser
  include ::Memoizable

  ASIN_REGEX = /(?:%2Fdp%2F|\/dp\/)([A-Z0-9]{10,})/i
  ORDER_ID_REGEX = /\b\d{3}-\d{7}-\d{7}\b/
  ORDER_HEADER_REGEX = /Order\s*#?\s*\d{3}-\d{7}-\d{7}/i
  DELIVERED_REGEXES = [
    /Your package was delivered/i,
    /Your package has been delivered/i,
    /Delivered\s+(today|yesterday)/i,
    /Arrived\b/i,
  ].freeze

  def self.parse(email, skip_ai_naming: false)
    Time.use_zone(User.timezone) {
      new(email, skip_ai_naming: skip_ai_naming).parse
    }
  end

  def initialize(email, skip_ai_naming: false)
    @email = email
    @skip_ai_naming = skip_ai_naming
  end

  def parse
    @changed = false
    @doc = Nokogiri::HTML(@email.to_html)
    return Jarvis.cmd("Add Amazon Email no order id: #{@email.id}") if order_id.blank?

    delivered = delivered_email?
    doall { |item|
      arrival_date(item).tap { |date|
        if date.present?
          item.delivery_date = date.iso8601.encode("UTF-8")
        elsif !delivered
          item.error!("Unable to parse date")
        end
      }
      item.time_range = arrival_time(item)
      item.name ||= safe_name(item)
      item.delivered = true if delivered
    }

    AmazonOrder.save
    AmazonOrder.broadcast
    @changed
  rescue StandardError => e
    SlackNotifier.err(
      e,
      "Error parsing Amazon:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>", username: "Mail-Bot", icon_emoji: ":mailbox:"
    )
    false
  end

  💾(:order_id) { @email.to_html[ORDER_ID_REGEX] }

  # The order details card - the .rio-card containing "Order # XXX-XXXXXXX-XXXXXXX"
  # along with the item images, names, and arrival info. Other rio-cards in the
  # email (step tracker, marketing slot, dividers) are skipped.
  💾(:order_card) {
    @doc.css(".rio-card").find { |card|
      card.text.include?(order_id) && card.css("a[href*='%2Fdp%2F'], a[href*='/dp/']").any?
    }
  }

  💾(:order_card_html) { order_card&.to_html.to_s }

  💾(:order_card_text) {
    order_card&.text.to_s.then { |t| t.gsub(/\s+/, " ").strip }
  }

  💾(:item_asins) {
    next [order_id] if order_card.nil?

    asins = order_card.css("a").flat_map { |a| a["href"].to_s.scan(ASIN_REGEX).flatten }.compact.uniq
    asins.presence || [order_id]
  }

  💾(:delivered_email?) {
    text = order_card_text.presence || @email.to_html
    DELIVERED_REGEXES.any? { |re| text.match?(re) }
  }

  def order_items
    @order_items ||= AmazonOrder.by_order(order_id).tap { |items|
      items.each do |item|
        @changed = true
        item.errors = []
        item.email_ids << @email.id unless item.email_ids.include?(@email.id)
      end
    }
  end

  def email_items
    @email_items ||= item_asins.map { |asin|
      AmazonOrder.find_or_create(order_id, asin).tap { |item|
        @changed = true
        item.errors = []
        item.email_ids << @email.id unless item.email_ids.include?(@email.id)
      }
    }
  end

  def doall(&block)
    items = email_items
    seen_ids = items.to_set(&:item_id)
    items.each { |item| block.call(item) }
    order_items.each { |item| block.call(item) unless seen_ids.include?(item.item_id) }
  end

  💾(:month_regex) {
    month_names = Date::MONTHNAMES.compact
    Regexp.new("\\b(?:#{month_names.flat_map { |m| [m, m.first(3)] }.join("|")})\\b")
  }

  💾(:wday_regex) {
    day_names = Date::DAYNAMES.compact
    Regexp.new("\\b(?:#{day_names.flat_map { |d| [d, d.first(3)] }.join("|")})\\b")
  }

  def future(date)
    loop { date.past? ? date += 1.week : (break date) }
  end

  def arrival_date(_item)
    text = order_card_text
    return nil if text.blank?

    # "Delivered today" / "Delivered yesterday" / "Your package was delivered"
    return Time.zone.today if text.match?(/Delivered\s+today|Your package was delivered|Your package has been delivered/i)
    return Time.zone.today - 1.day if text.match?(/Delivered\s+yesterday/i)

    # "Arriving overnight ..." - overnight means by the next morning
    return Time.zone.today + 1.day if text.match?(/Arriving\s+overnight/i)

    # "Arriving today" / "Arriving tomorrow"
    return Time.zone.today if text.match?(/Arriving\s+today/i)
    return Time.zone.today + 1.day if text.match?(/Arriving\s+tomorrow/i)

    # "Arriving <Weekday>" - parse to next occurrence
    if (match = text.match(/Arriving\s+(#{wday_regex})/))
      return future(Date.parse(match[1]))
    end

    # "Arriving <Month> <day>" - explicit date
    if (match = text.match(/Arriving\s+(?:by\s+)?(#{month_regex}\s+\d{1,2})/))
      return future(Date.parse(match[1]))
    end

    # "Arriving between <Month> <day>" - take the lower bound
    if (match = text.match(/Arriving\s+between\s+(#{month_regex}\s+\d{1,2})/))
      return future(Date.parse(match[1]))
    end

    # Fallback - bare "Month Day" anywhere in the card
    if (date_str = text[/(#{month_regex})\s+\d{1,2}/])
      return future(Date.parse(date_str))
    end

    nil
  rescue StandardError
    nil
  end

  def arrival_time(_item)
    text = order_card_text
    return if text.blank?

    match = text.match(/(\d{1,2} ?[ap]\.?m\.?)\W{1,5}(\d{1,2} ?[ap]\.?m\.?)/i)
    return if match.blank?

    _, start_range, end_range = match.to_a
    meridian = (end_range || start_range).gsub(/[^a-z]/i, "")
    [start_range, end_range].compact.map { |t| t.gsub(/\D/, "") }.join("-") + meridian
  end

  # Falls back to the email's listed_name if AI naming is disabled OR the AI call fails
  # (e.g. OpenAI quota exceeded). The parsed shipment data must always persist regardless
  # of name-cleanup status.
  def safe_name(item)
    return item.listed_name.to_s.presence || full_name(item).to_s.presence if @skip_ai_naming

    shortened_name(item).presence || item.listed_name.to_s.presence || full_name(item).to_s.presence
  rescue StandardError => e
    SlackNotifier.err(e, "Amazon name lookup failed for email ##{@email.id}, falling back to listed_name")
    item.listed_name.to_s.presence || full_name(item).to_s.presence
  end

  def shortened_name(item)
    ChatGPT.short_name_from_order(full_name(item), item).to_s
  end

  def full_name(item)
    item.full_name ||= (
      item.listed_name ||= @email.subject.to_s[/^[^"]*"(.*?)"[^"]*$/, 1]
      item.listed_name ||= name_from_card(item)
      count = @email.subject.to_s[/(\d+ ?x) ?"/, 1]

      if item.listed_name.to_s.include?("...")
        [
          count,
          retrieve_full_name(item).presence || item.listed_name,
        ].filter_map(&:presence).join(" ")
      else
        [count, item.listed_name].filter_map(&:presence).join(" ")
      end
    )
  end

  def name_from_card(item)
    link = order_card&.css("a")&.find { |a| a["href"].to_s.include?(item.item_id) }
    link&.text&.squish.presence
  end

  def retrieve_full_name(item)
    res = ::RestClient.get(item.url)
    item_doc = Nokogiri::HTML(res.body)
    name = item_doc.title[/(?:[^:]*? : |Amazon.com: )(.*?) : [^:]*?/im, 1]
    return name if name.present?

    name = item_doc.title.split(": Amazon.com").first
    error("Unable to parse title: [#{item.item_id}]:#{item_doc.title}") if name.blank?

    name.to_s
  rescue StandardError
    # Amazon occasionally serves a captcha; swallow and move on.
  end

  def error(msg="Failed to parse")
    Jarvis.say("Add Amazon Email #{msg}: #{@email.id}")
  end
end
