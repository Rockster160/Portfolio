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
    #               carrier + source. Delivered rows are never weak-matched so a
    #               delivered "NINGBO DEYI SAM" package can't absorb a brand-new
    #               order from the same sender. Ambiguous (>1) falls through.
    #   3. Otherwise create a new item using the §identity scheme.
    #
    # On a weak hit that had no tracking_number, back-fills it from this update
    # so every subsequent update matches on the strong key.
    def connect_or_create(carrier:, tracking_number: nil, source: nil, name: nil)
      carrier = carrier.to_sym
      tracking_number = tracking_number.presence
      source = source.presence

      if tracking_number && (hit = by_tracking(tracking_number))
        return hit
      end

      if source && (hit = single_active_by_source(carrier, source))
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

    def single_active_by_source(carrier, source)
      matches = AmazonOrder.all.select { |o|
        o.carrier == carrier && o.source == source && !o.delivered
      }
      matches.first if matches.one?
    end
  end
end
