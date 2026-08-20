class AmazonOrder
  attr_accessor(
    :order_id,
    :item_id,
    :listed_name,
    :full_name,
    :name,
    :delivery_date,
    :time_range,
    :delivered,
    :status,
    :order_id_confirmed,
    :email_ids,
    :errors,
    :amount,
    :just_added,
    :carrier,
    :tracking_number,
    :source,
    :custom_url,
  )

  # Public tracking URL per carrier. Amazon rows keep the historical product
  # link; other carriers link to their tracking page by tracking number.
  CARRIER_TRACKING_URLS = {
    ups:   "https://www.ups.com/track?tracknum=%<tracking>s",
    usps:  "https://tools.usps.com/go/TrackConfirmAction?tLabels=%<tracking>s",
    fedex: "https://www.fedex.com/fedextrack/?trknbr=%<tracking>s",
  }.freeze

  # The carriers somebody can NAME. `manual` is the absence of one — what a
  # hand-added row starts as — so it isn't in here; `amazon` has no template
  # because those rows keep their product link instead, and `wayfair` (like
  # amazon, a merchant reporting its own shipments) links through the per-order
  # short link its texts carry, in `custom_url`.
  #
  # Derived from the URL map rather than listed again, so a carrier is
  # sayable exactly when there's somewhere to send its tracking number.
  NAMED_CARRIERS = (CARRIER_TRACKING_URLS.keys + [:amazon]).freeze

  def self.all
    @@all ||= reload
  end

  def self.reload
    @@all = (MeCache.get(:amazon_deliveries) || []).map { |data| new(data) }
    # What the list looked like before anybody touched it, for the lifecycle
    # diff in `save`. Taken HERE because this is the only moment we know
    # nothing has been changed yet — re-reading the cache at save time would
    # already be looking at whatever we're about to overwrite.
    @@snapshot = @@all.map(&:serialize)
    @@all
  end

  def self.save
    # `serialize` first: on a cold process it loads the list, which is what
    # sets the snapshot this then diffs against.
    after  = serialize
    before = defined?(@@snapshot) ? @@snapshot : nil
    MeCache.set(:amazon_deliveries, after)
    DeliveryEvents.fire!(before: before, after: after)
    clear
  end

  def self.clear
    @@all = nil
    @@snapshot = nil
  end

  def self.broadcast
    clear # Get a fresh broadcast
    ActionCable.server.broadcast(:amz_updates_channel, serialize)
    clear # Clear for next
  end

  def self.ordered
    all.sort_by { |order| order.delivery_time || 1.year.from_now }
  end

  def self.serialize
    ordered.map(&:serialize)
  end

  def self.reparse(email_or_email_id)
    email = email_or_email_id.is_a?(Email) ? email_or_email_id : Email.find(email_or_email_id)
    AmazonEmailParser.parse(email)
  end

  def self.find(order_id, item_id=nil)
    all.find { |order|
      next unless order.order_id == order_id

      item_id.nil? || order.item_id == item_id
    }
  end

  def self.by_order(order_id)
    all.select { |order| order.order_id == order_id }
  end

  def self.find_or_create(order_id, item_id)
    find(order_id, item_id) || create(order_id: order_id, item_id: item_id)
  end

  def self.create(order_hash={})
    new(order_hash.merge(just_added: true)).tap { |item| all << item }
  end

  # NOTE: Do not use `new` directly, use `create` instead
  def initialize(order_hash={})
    @order_id = "CUSTOM"
    @item_id = "CUSTOM-#{SecureRandom.hex(2)}"
    @errors = []
    @email_ids = []
    @just_added = false # Gets overridden
    # Default carrier keeps every pre-carrier cached row (and the whole Amazon
    # path) reading back as :amazon with no migration. order_hash can override.
    @carrier = :amazon
    # Guard on the SETTER, not the getter: `serialize` includes computed,
    # read-only fields (e.g. `url`) that round-trip into the cache but have no
    # writer. Assigning only when a writer exists ignores those on reload.
    order_hash.each do |key, val|
      send(:"#{key}=", val) if respond_to?(:"#{key}=")
    end
  end

  # MeCache round-trips through JSON, so a stored symbol comes back a string.
  # Normalize to a symbol so `carrier` is always the enum-style symbol the rest
  # of the code (and #url) expects, whether freshly set or reloaded.
  def carrier=(val)
    @carrier = val.presence&.to_sym
  end

  def reparse(email_id=nil)
    email_id ||= email_ids.last
    AmazonEmailParser.parse(Email.find(email_id))
  end

  # TODO: Create an emails api
  # def prod_email
  #   ProdApi.get([:emails, email_ids.last])
  # end

  def url
    template = CARRIER_TRACKING_URLS[carrier]
    return format(template, tracking: tracking_number) if template && tracking_number.present?

    # A non-Amazon item without a tracking number (e.g. a UPS SMS that only named
    # the sender) has no meaningful link — don't fall back to an Amazon product URL.
    return nil if carrier && carrier != :amazon

    "https://www.amazon.com/dp/#{item_id}"
  end

  def delivery_date=(date)
    @delivery_date = date ? date.to_date.iso8601.encode("UTF-8") : nil
  end

  def delivery_time
    return if @delivery_date.blank?

    start_time, end_time = time_range.to_s.split("-")
    time = start_time.present? ? " #{start_time.to_s[/\d+/]}#{start_time.to_s[/\wm/i] || end_time.to_s[/\wm/i]}" : nil

    User.timezone {
      Time.zone.parse("#{@delivery_date}#{time}").then { |t|
        time.nil? ? t.end_of_day : t
      }
    }
  rescue ArgumentError, Date::Error
    nil
  end

  def destroy
    # Same ASIN can legitimately appear under multiple order_ids (subscribe & save,
    # re-orders, split shipments). Only drop the specific (order_id, item_id) pair.
    @@all = AmazonOrder.all.reject { |order|
      order.order_id == order_id && order.item_id == item_id
    }
    self
  end

  def error!(str)
    @errors ||= []
    @errors.push(str)
  end

  # Fold `other` into this item and drop `other`. Used by the manual `2+4`
  # merge: the target keeps its own display info (name/listed_name/full_name)
  # while adopting the source's shipping/tracking data so future updates
  # (matched by tracking_number) land on this row. Email history is unioned.
  def merge!(other)
    self.carrier         = other.carrier
    self.tracking_number = other.tracking_number
    self.source          = other.source
    self.delivery_date   = other.delivery_date
    self.time_range      = other.time_range
    self.delivered       = other.delivered
    self.status          = other.status
    self.email_ids       = (Array(email_ids) + Array(other.email_ids)).uniq
    self.amount        ||= other.amount
    # Keep the target's own link (part of its basic info); only adopt the
    # source's if the target didn't have one.
    self.custom_url    ||= other.custom_url
    other.destroy
    self
  end

  def serialize
    {
      order_id:           order_id,
      item_id:            item_id,
      listed_name:        listed_name,
      full_name:          full_name,
      name:               name,
      delivery_date:      delivery_date,
      time_range:         time_range,
      delivered:          delivered,
      status:             status,
      order_id_confirmed: order_id_confirmed,
      email_ids:          email_ids,
      errors:             errors,
      amount:             amount,
      carrier:            carrier,
      tracking_number:    tracking_number,
      source:             source,
      custom_url:         custom_url,
      url:                url,
    }
  end
end
