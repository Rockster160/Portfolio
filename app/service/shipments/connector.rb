module Shipments
  # Resolves which AmazonOrder an incoming carrier update belongs to, or creates
  # a new one. Identity (order_id, item_id) is immutable once created — this only
  # ever mutates the connection keys (tracking_number/carrier/source) via
  # back-fill, never item_id (the frontend keys its rows on it).
  module Connector
    module_function

    # Returns the AmazonOrder this update should update. Match order:
    #   1. STRONG — an item with the exact same tracking_number (any state).
    #   2. WEAK   — exactly ONE active (non-delivered) item with the same
    #               carrier + `connect_on` value. Delivered rows are never
    #               weak-matched so a delivered "NINGBO DEYI SAM" package can't
    #               absorb a brand-new order from the same sender. Ambiguous
    #               (>1) falls through.
    #   3. Otherwise create a new item using the §identity scheme.
    #
    # `connect_on` picks WHICH attribute the weak tier compares. A UPS text
    # identifies a shipment by its sender, so :source is right there. A Wayfair
    # text always says "Wayfair" — the product it names is the only thing
    # telling two of them apart — so it connects on :name instead.
    #
    # On a weak hit that had no tracking_number, back-fills it from this update
    # so every subsequent update matches on the strong key.
    def connect_or_create(carrier:, tracking_number: nil, source: nil, name: nil, connect_on: :source)
      carrier = carrier.to_sym
      tracking_number = tracking_number.presence
      source = source.presence

      if tracking_number && (hit = by_tracking(tracking_number))
        return hit
      end

      weak_key = (connect_on.to_sym == :name ? name : source).presence
      if weak_key && (hit = single_active_by(carrier, connect_on, weak_key))
        hit.tracking_number ||= tracking_number
        return hit
      end

      AmazonOrder.create(
        carrier:         carrier,
        tracking_number: tracking_number,
        source:          source,
        name:            name.presence || source,
        order_id:        carrier.to_s.upcase,
        item_id:         tracking_number || "#{carrier.to_s.upcase}-#{SecureRandom.hex(2)}",
      )
    end

    def by_tracking(tracking_number)
      AmazonOrder.all.find { |o|
        o.tracking_number.present? && o.tracking_number == tracking_number
      }
    end

    def single_active_by(carrier, attr, value)
      matches = AmazonOrder.all.select { |o|
        o.carrier == carrier && !o.delivered && o.public_send(attr).to_s.casecmp?(value.to_s)
      }
      matches.first if matches.one?
    end
  end
end
