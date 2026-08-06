module DeliveryEvents
  # Jil triggers for the delivery list: `delivery:action:created`,
  # `:updated`, `:delivered`, `:delayed`.
  #
  # AmazonOrder is a cache-backed PORO, so there are no model callbacks to hang
  # these off. Every writer goes through AmazonOrder.save though — both email
  # parsers, the dashboard channel, and Buddy — so diffing what changed there
  # catches all of them at once and none of them has to remember to announce
  # itself.

  module_function

  SCOPE = :delivery

  # The fields that describe the DELIVERY. `email_ids` and `errors` are
  # bookkeeping that churns on every re-parse, and firing an `updated` because
  # an email id got appended would make the trigger useless to listen on.
  FACTS = %i[
    name
    listed_name
    full_name
    delivery_date
    time_range
    delivered
    status
    carrier
    tracking_number
    source
    custom_url
    amount
  ].freeze

  def fire!(before:, after:, user: User.me)
    return if user.nil?

    changes(index(before), index(after)).each { |action, row, was|
      # `auth: :trigger` is the default, and it's here anyway: `Jil.trigger`
      # takes keyword args after `data`, so without a keyword to pin it the
      # payload gets read as keywords and the call dies with "Invalid keyword
      # arguments provided". Same reason ListItem passes it.
      ::Jil.trigger(user, SCOPE, payload(action, row, was), auth: :trigger)
    }
  rescue StandardError => e
    # Announcing a write must never be able to lose it. The row is already
    # saved by the time this runs.
    Rails.logger.warn("[DeliveryEvents] #{e.class}: #{e.message}")
  end

  # Keyed by the pair that identifies a shipment. The same ASIN legitimately
  # appears under several order_ids (subscribe & save, re-orders, split
  # shipments), which is why it takes both.
  def index(list)
    Array(list).filter_map { |entry|
      row = entry.respond_to?(:serialize) ? entry.serialize : entry
      next nil unless row.is_a?(Hash)

      row = row.symbolize_keys
      [[row[:order_id].to_s, row[:item_id].to_s], row]
    }.to_h
  end

  # One event per row per save, most specific first: a package that arrived is
  # DELIVERED, not "updated, and by the way the delivered flag moved".
  def changes(before, after)
    after.filter_map { |key, row|
      was = before[key]
      next [:created, row, nil] if was.nil?
      next [:delivered, row, was] if arrived?(was, row)
      next [:delayed, row, was] if slipped?(was, row)
      next [:updated, row, was] if row.values_at(*FACTS) != was.values_at(*FACTS)

      nil
    }
  end

  def arrived?(was, now)
    !truthy?(was[:delivered]) && truthy?(now[:delivered])
  end

  # Later than it was. A date moving EARLIER is good news and an ordinary
  # update; only a slip is worth its own trigger.
  def slipped?(was, now)
    old_day = day(was[:delivery_date])
    new_day = day(now[:delivery_date])
    return false if old_day.nil? || new_day.nil?

    new_day > old_day
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value).present?
  end

  def day(value)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Flat, so a listener can filter on any of it the way it would any other
  # scope: `delivery:action:delayed`, `delivery:carrier:ups`,
  # `delivery:name:/desk/i`.
  #
  # String keys, matching what ListItem hands over (`serialize` output) so a
  # listener reads every scope the same way.
  def payload(action, row, was)
    {
      "action"          => action.to_s,
      "name"            => row[:name].to_s,
      "carrier"         => row[:carrier].to_s,
      "tracking_number" => row[:tracking_number].to_s,
      "delivery_date"   => row[:delivery_date].to_s,
      # Only on a slip, and it's the whole point of the event: what it WAS.
      "previous_date"   => (was[:delivery_date].to_s if action == :delayed && was),
      "delivered"       => truthy?(row[:delivered]),
      "amount"          => row[:amount],
      "order_id"        => row[:order_id].to_s,
      "item_id"         => row[:item_id].to_s,
      "url"             => row[:url].to_s,
    }.compact
  end
end
