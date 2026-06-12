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

    if order_card.nil?
      # No item card → we can't tell which items shipped. Flag for manual review
      # rather than guessing (a bare "Delivered: Order # …" notice doesn't promise
      # the WHOLE order delivered — siblings may still be in transit).
      tag = delivered ? "delivered, no order card" : "no order card"
      return Jarvis.cmd("Add Amazon Email #{tag}: #{@email.id}")
    end

    # Only update state for items actually referenced by this email's order card.
    # Other items on the same order_id (shipped/delivered separately) keep their own state.
    # Multi-order emails (one rio-card listing items from two distinct order_ids)
    # are handled per-asin via asin_card_text / asin_order_id.
    new_status = status_from_subject
    prefetch_names!(email_items)
    email_items.each { |item|
      text = asin_card_text(item.item_id)
      item_delivered = delivered_text?(text)
      arrival_date_from(text).tap { |date|
        if date.present?
          item.delivery_date = date.iso8601.encode("UTF-8")
        elsif !item_delivered && new_status.nil?
          item.error!("Unable to parse date")
        end
      }
      item.time_range = arrival_time_from(text)
      item.name ||= safe_name(item)
      item.delivered = true if item_delivered
      apply_status(item, new_status)
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

  # The order details card - the .rio-card containing "Order # XXX-XXXXXXX-XXXXXXX"
  # along with the item images, names, and arrival info. Other rio-cards in the
  # email (step tracker, marketing slot, dividers) are skipped.
  # Pick the rio-card with item links. Prefer one whose text also prints the
  # "Order # XXX..." header (most reliable order_id), but fall back to any card
  # with /dp/ links - delivery-update / late notices sometimes omit the header
  # inside the item card and put it elsewhere in the email.
  💾(:order_card) {
    candidates = @doc.css(".rio-card").select { |card|
      card.css("a[href*='%2Fdp%2F'], a[href*='/dp/']").any?
    }
    candidates.find { |c| c.text.match?(ORDER_ID_REGEX) } || candidates.first
  }

  # Trust the order id printed on the order card over the first regex match in
  # the html. Footers/banners can mention unrelated orders ("track another order")
  # and we don't want to attribute the email to the wrong one.
  💾(:order_id) { order_card&.text&.[](ORDER_ID_REGEX) || @email.to_html[ORDER_ID_REGEX] }

  💾(:order_card_html) { order_card&.to_html.to_s }

  💾(:order_card_text) {
    order_card&.text.to_s.then { |t| t.gsub(/\s+/, " ").strip }
  }

  💾(:item_asins) {
    next [] if order_card.nil?

    order_card.css("a").flat_map { |a| a["href"].to_s.scan(ASIN_REGEX).flatten }.compact.uniq
  }

  💾(:delivered_email?) {
    delivered_text?(order_card_text.presence || @email.to_html)
  }

  def delivered_text?(text)
    return false if text.blank?

    DELIVERED_REGEXES.any? { |re| text.match?(re) }
  end

  # nil for normal emails; :cancelled for "Item cancelled" notifications;
  # :declined for "Payment declined" / order-on-hold notifications.
  💾(:status_from_subject) {
    subj = @email.subject.to_s
    next :cancelled if subj.match?(/\b(?:items?\s+)?cancell?ed\b|\bcancellation\b/i)
    next :declined  if subj.match?(/payment\s+(?:was\s+)?declined|payment\s+revision\s+needed/i)

    nil
  }

  # Cancelled is sticky (Amazon doesn't un-cancel an order). Declined is transient -
  # a subsequent "Shipped"/"Delivered" email clears it back to active (nil).
  def apply_status(item, new_status)
    return if item.status == :cancelled

    item.status = new_status
  end

  def email_items
    @email_items ||= item_asins.map { |asin|
      AmazonOrder.find_or_create(asin_order_id(asin), asin).tap { |item|
        @changed = true
        item.errors = []
        item.email_ids << @email.id unless item.email_ids.include?(@email.id)
      }
    }
  end

  # Walks up the DOM from each ASIN's /dp/ link to find the smallest ancestor
  # within the order_card that names exactly one order_id. That sub-block is
  # what we attribute the ASIN's order_id / arrival date / delivered state / etc
  # to. Falls back to the order_card itself when the ASIN's sub-block can't be
  # isolated (single-order emails always fall back, which preserves prior behavior).
  def asin_subcard(asin)
    return nil if order_card.nil? || asin.blank?

    @asin_subcards ||= {}
    return @asin_subcards[asin] if @asin_subcards.key?(asin)

    link = order_card.css("a[href*='%2Fdp%2F'], a[href*='/dp/']").find { |a|
      a["href"].to_s[ASIN_REGEX, 1] == asin
    }
    return @asin_subcards[asin] = nil if link.nil?

    node = link.parent
    stop_at = order_card.parent
    while node && node != stop_at
      ids = node.text.scan(ORDER_ID_REGEX).uniq
      break if ids.size > 1 # ambiguous - walked into multi-order container
      if ids.size == 1
        @asin_subcards[asin] = node
        return node
      end
      node = node.parent
    end
    @asin_subcards[asin] = nil
  end

  def asin_order_id(asin)
    asin_subcard(asin)&.text&.[](ORDER_ID_REGEX) || order_id
  end

  def asin_card_text(asin)
    (asin_subcard(asin) || order_card)&.text.to_s.then { |t| t.gsub(/\s+/, " ").strip }
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

  def arrival_date_from(text)
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

    # "Arriving <Month> <day>" / "Estimated to arrive by <Month> <day>" - explicit date
    if (match = text.match(/(?:Arriving|Estimated\s+to\s+arrive)\s+(?:by\s+)?(#{month_regex}\s+\d{1,2})/i))
      return future(Date.parse(match[1]))
    end

    # "Arriving between <Month> <day>" - take the lower bound
    if (match = text.match(/Arriving\s+between\s+(#{month_regex}\s+\d{1,2})/))
      return future(Date.parse(match[1]))
    end

    # Fallback - bare "Month Day" anywhere in the text
    if (date_str = text[/(#{month_regex})\s+\d{1,2}/])
      return future(Date.parse(date_str))
    end

    nil
  rescue StandardError
    nil
  end

  def arrival_time_from(text)
    return if text.blank?

    match = text.match(/(\d{1,2} ?[ap]\.?m\.?)\W{1,5}(\d{1,2} ?[ap]\.?m\.?)/i)
    return if match.blank?

    _, start_range, end_range = match.to_a
    meridian = (end_range || start_range).gsub(/[^a-z]/i, "")
    [start_range, end_range].compact.map { |t| t.gsub(/\D/, "") }.join("-") + meridian
  end

  # Resolves a display name for `item`. The expensive GPT call has already been
  # done in bulk by `prefetch_names!`; this is just the catalog lookup with a
  # listed_name/full_name fallback. As a side effect we also push the resolved
  # listed_name/full_name into the catalog so subsequent emails (and the next
  # ASIN that ships under this ID) see them even when GPT is disabled. The
  # catalog's `name:` field is left alone here - prefetch_names! and manual
  # renames are the only writers for that.
  def safe_name(item)
    cached = AmazonItemCatalog.get(item.item_id)
    if cached
      item.listed_name ||= cached[:listed_name]
      item.full_name   ||= cached[:full_name]
      return cached[:name] if cached[:name].present?
    end

    resolved = item.listed_name.to_s.presence || full_name(item).to_s.presence

    if item.listed_name.present? || item.full_name.present?
      AmazonItemCatalog.set(item.item_id,
        listed_name: item.listed_name,
        full_name:   item.full_name,
      )
    end

    resolved
  end

  # ONE GPT call per email instead of one per ASIN. Resolves clean short names
  # for every email_item whose ASIN isn't already cached, and writes them to
  # the catalog so a subsequent re-order of the same SKU is free.
  def prefetch_names!(items)
    return if @skip_ai_naming
    return if items.empty?

    needs_lookup = items.reject { |i| AmazonItemCatalog.get(i.item_id)&.dig(:name).to_s.presence }
    titles = needs_lookup.map { |i| full_name(i).to_s }
    pairs = needs_lookup.zip(titles).reject { |_, t| t.blank? }
    return if pairs.empty?

    return # Disabling GPT for now - need to update API Tokens
    # cleaned = ChatGPT.short_names_from_orders(pairs.map(&:last))
    # pairs.zip(cleaned).each { |(item, _title), name|
    #   next if name.blank?

    #   AmazonItemCatalog.set(item.item_id,
    #     name:        name,
    #     listed_name: item.listed_name,
    #     full_name:   item.full_name,
    #   )
    # }
  rescue StandardError => e
    SlackNotifier.err(e, "Amazon batch name lookup failed for email ##{@email.id} - falling back to listed_name")
  end

  def full_name(item)
    item.full_name ||= (
      # name_from_card is per-ASIN. Subject quote only matches the first item, so when
      # multiple items ship on one order it would assign the same name to every item.
      item.listed_name ||= name_from_card(item)
      item.listed_name ||= @email.subject.to_s[/^[^"]*"(.*?)"[^"]*$/, 1]
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
    # Each item has multiple anchors (image wrapper + text), so pick the first one
    # that has visible text — the image link's text is blank.
    order_card&.css("a")&.filter_map { |a|
      next unless a["href"].to_s.include?(item.item_id)

      a.text.squish.presence
    }&.first
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
