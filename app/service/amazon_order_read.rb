# Brings Amazon orders up to date from the Mini reading their pages
# (~/code/Byte/amazon/orders.js): each item by ASIN, with an everyday name, the
# day and time it's expected, and whether it was delivered or cancelled.
#
# Every Amazon email sets a read off (ReceiveEmailWorker), for the orders it
# names and every order still on the way, so an email that never came is made
# up for by the next one. AmazonReadWorker also runs once a day for a quiet
# day. The page is the truth for an item; emails that hide what's in an order
# leave named items alone (AmazonEmailParser#parse_no_card_email).
#
# What the Mini sends:
#   { read_at:, orders: [{ order_id:, shipments: [{ status:, promise:, promise_box:,
#       progress:, tracking_id:, items: [{ asin:, title:, quantity:, text: }] }] }] }
#   an order it couldn't read is { order_id:, error: }, and a read that
#   couldn't start is { error:, needs_person: }.
module AmazonOrderRead
  extend Shipments::DateParsing

  module_function

  ORDER_ID_REGEX = /\b\d{3}-\d{7}-\d{7}\b/
  SIGN_IN_KEY = "amazon:sign-in".freeze

  # A package's status line, by what it means for its items. Returned and
  # refunded items came first.
  CANCELLED = /\bcancel/i
  DELIVERED = /\A\s*(?:Delivered|Return|Refund)/i

  def order_ids_in(*texts)
    texts.flat_map { |text| text.to_s.scan(ORDER_ID_REGEX) }.uniq
  end

  # Returns how many orders were brought up to date.
  def apply!(payload, user: User.me)
    payload = payload.to_h.deep_symbolize_keys
    if payload[:error].present?
      note_needs_person!(user, payload[:error]) if payload[:needs_person]
      return 0
    end

    BackgroundProcess.clear(user: user, key: SIGN_IN_KEY)
    orders = Array(payload[:orders]).select { |order| order[:error].blank? && items_of(order).any? }
    return 0 if orders.empty?

    Time.use_zone(User.timezone) {
      AmazonOrder.reload
      keep_stand_in_names!(orders)
      name!(orders, user)
      orders.each { |order| apply_order(order) }
      AmazonOrder.save
      AmazonOrder.broadcast
    }
    orders.length
  end

  # [[shipment, item], ...]
  def items_of(order)
    Array(order[:shipments]).flat_map { |shipment|
      items = Array(shipment[:items]).select { |item| item[:asin].present? }
      items.map { |item| [shipment, item] }
    }
  end

  # The row an email made for the whole order before anything said what was
  # in it. Once the page names the items it goes, and a name it was given by
  # hand moves to the item, when there's only one for it to mean.
  def keep_stand_in_names!(orders)
    orders.each { |order|
      stand_in = AmazonOrder.find(order[:order_id], order[:order_id])
      entries = items_of(order)
      next if stand_in.nil? || entries.length != 1
      next if stand_in.name == stand_in.listed_name

      item = entries.first.last
      next unless own_name?(stand_in.name, item[:title])
      next if label_for(item[:asin], item[:title])

      AmazonItemCatalog.set(item[:asin], name: stand_in.name, source: :typed)
    }
  end

  # One model call for every product without a label yet. A label already in
  # the catalog stays (label_for); anything else there is replaced. When the
  # call fails nothing is stored, so the next read asks again.
  def name!(orders, user)
    items = orders.flat_map { |order| items_of(order).map(&:last) }
    titles = items.to_h { |item| [item[:asin], item[:title].to_s] }
    unnamed = titles.select { |asin, title| title.present? && label_for(asin, title).nil? }
    return if unnamed.empty?

    names = AmazonFriendlyName.call(unnamed.values, user: user)
    unnamed.keys.each_with_index { |asin, index|
      next if names[index].blank?

      AmazonItemCatalog.set(asin, name: names[index], full_name: unnamed[asin], source: :named)
    }
  end

  # A catalog name typed by the person or given by AmazonFriendlyName. One
  # from before either is kept only when it reads as the person's own.
  def label_for(asin, title)
    entry = AmazonItemCatalog.get(asin) || {}
    return entry[:name] if entry[:source].present? && entry[:name].present?

    entry[:name] if own_name?(entry[:name], title)
  end

  # Short, and not just words lifted from the title.
  def own_name?(name, title)
    AmazonFriendlyName.label?(name) && !AmazonFriendlyName.from_title?(name, title)
  end

  def apply_order(order)
    order_id = order[:order_id]
    stand_in = AmazonOrder.find(order_id, order_id)
    items_of(order).each { |shipment, item| apply_item(order_id, shipment, item, stand_in) }
    stand_in&.destroy
  end

  def apply_item(order_id, shipment, item, stand_in)
    asin = item[:asin]
    return if AmazonOrder.removed?(order_id, asin)

    row = AmazonOrder.find(order_id, asin) || AmazonOrder.create(order_id: order_id, item_id: asin)
    row.order_id_confirmed = true
    row.full_name = item[:title] if item[:title].present?
    row.listed_name ||= item[:title]
    # Without a label yet, the tidied title until the next read names it: long,
    # but it still says what the thing is, where a cut to fit would often not.
    row.name = (
      label_for(asin, item[:title]) ||
      (row.name if own_name?(row.name, item[:title])) ||
      AmazonProductName.tidy(item[:title])
    )
    row.email_ids = (Array(row.email_ids) + Array(stand_in&.email_ids)).uniq
    row.tracking_number = shipment[:tracking_id] if shipment[:tracking_id].present?
    row.errors = []
    apply_state(row, shipment, item)
  end

  # Cancelled stays cancelled, and delivered stays delivered: Amazon undoes
  # neither, and a "it came" said by hand is taken over a page that hasn't
  # caught up.
  def apply_state(row, shipment, item)
    status = shipment[:status].to_s
    return row.status = :cancelled if status.match?(CANCELLED) || item[:text].to_s.match?(CANCELLED)
    return if row.status == :cancelled

    row.status = nil
    if status.match?(DELIVERED) || shipment[:promise].to_s.match?(DELIVERED)
      row.delivered = true
      row.delivery_date = delivered_on(status) || row.delivery_date || Time.zone.today
      return
    end
    return if row.delivered

    arriving = shipment[:promise].presence || status
    date = arrival_date_from(arriving)
    row.delivery_date = date if date
    window = [arriving, shipment[:promise_box]].compact_blank.join(" ")
    row.time_range = arrival_time_from(window) || deadline_time_from(window)
  end

  # "Delivered November 11" is in the past, never next year.
  def delivered_on(text)
    return Time.zone.today if text.match?(/Delivered\s+today/i)
    return Time.zone.yesterday if text.match?(/Delivered\s+yesterday/i)

    month = Shipments::DateParsing::MONTH_REGEX
    match = text.match(/Delivered\s+(?:\w+day,?\s+)?(#{month}\s+\d{1,2})/i)
    return if match.nil?

    date = Date.parse("#{match[1]} #{Time.zone.today.year}")
    date > Time.zone.today ? date.prev_year : date
  rescue Date::Error
    nil
  end

  def note_needs_person!(user, said)
    BackgroundProcess.note(
      user:   user,
      key:    SIGN_IN_KEY,
      name:   "Amazon sign-in",
      detail: said,
      state:  :waiting,
      source: :mac,
    )
  end
end
