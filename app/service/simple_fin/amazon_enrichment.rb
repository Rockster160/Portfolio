module SimpleFin
  # Carries what an Amazon purchase WAS onto the charge for it: the order
  # number, the item ids, a readable memo, and a category better than
  # "shopping".
  #
  # The historical backfill did this from a downloaded order history. This is
  # the same thing for purchases arriving from now on, reading the delivery
  # board (`AmazonOrder`) instead of a CSV — so a charge that lands while an
  # order is still in flight picks up the same three things, written to the same
  # place, by the same rules.
  #
  # Best-effort by nature. The board is a live list of what is currently on its
  # way, not a purchase archive: rows leave it once delivered, and `amount` is
  # populated on some but not all. A charge that finds nothing is left exactly
  # as it was.
  class AmazonEnrichment
    # Amazon authorizes at order time and captures at shipment, so the charge
    # can sit a few days from the delivery record's own date. Same window the
    # order-history backfill used, chosen the same way.
    WINDOW = 3.days

    PAYEE = /amazon|amzn/i
    # A real Amazon order number. The board also holds hand-added rows ("CUSTOM")
    # and other carriers, which are not what this is for.
    ORDER_ID = /\A\d{3}-\d{7}-\d{7}\z/

    class << self
      # Returns the transaction when it wrote something, nil otherwise.
      def apply(transaction)
        return nil unless amazon?(transaction)
        return nil if transaction.metadata.to_h["amazon"].present?

        order = match_for(transaction)
        return nil if order.nil?

        write!(transaction, order)
        transaction
      end

      def amazon?(transaction)
        return false if transaction.nil?

        "#{transaction.payee} #{transaction.description}".match?(PAYEE)
      end

      # The delivery whose amount and date fit this charge. Nearest in time
      # where several fit, which is the rule used everywhere else a charge is
      # matched to something — see EventMatcher.nearest.
      def match_for(transaction)
        cents = transaction.amount_cents.abs
        at = transaction.occurred_at
        return nil if cents.zero? || at.blank?

        claimed = claimed_order_ids
        candidates = orders.select { |order|
          order_cents(order) == cents && within_window?(order, at) &&
            claimed.exclude?(order.order_id)
        }
        candidates.min_by { |order| [(order_time(order) - at).abs, order.order_id.to_s] }
      end

      private

      def orders
        ::AmazonOrder.all.select { |order| order.order_id.to_s.match?(ORDER_ID) }
      rescue ::StandardError => e
        # The board is a cache. A charge is not worth failing a sync over.
        ::Rails.logger.warn("[SimpleFin::AmazonEnrichment] delivery board unreadable: #{e.message}")
        []
      end

      # One delivery explains one charge. Without this, two charges of the same
      # size would both claim it and one would be wrong.
      def claimed_order_ids
        ::BankTransaction.where("metadata -> 'amazon' ? 'order_id'").filter_map { |row|
          row.metadata.dig("amazon", "order_id")
        }.to_set
      end

      def order_cents(order)
        raw = order.amount
        return 0 if raw.blank?

        (BigDecimal(raw.to_s.delete("$,")) * 100).round.abs
      rescue ::ArgumentError
        0
      end

      def order_time(order)
        ::Time.zone.parse(order.delivery_date.to_s)
      rescue ::ArgumentError, ::TypeError
        ::Time.at(0).utc
      end

      def within_window?(order, at)
        time = order_time(order)
        return false if time.to_i.zero?

        (time - at).abs <= WINDOW
      end

      def write!(transaction, order)
        name = order.full_name.presence || order.name.presence || order.listed_name
        attrs = {}

        memo = ::AmazonProductName.tidy(name)
        attrs[:memo] = memo if memo.present? && auto_filled?(transaction)

        # Categorized on the TIDIED name, not the raw title. A title is search
        # spam and mentions everything the thing could conceivably be near: a
        # soup bowl reads "Stoneware Cereal Set of 4", which lands it in
        # groceries. The tidied name is both more accurate and the text shown
        # in the memo, so the category always agrees with what is on screen.
        category = ::TransactionCategory.for_item(memo)
        attrs[:category] = category.to_s if category.present?

        # The category is recorded ALONGSIDE being set, exactly as the
        # order-history backfill does. That is what lets either writer tell its
        # own answer from one you picked by hand — without it, a category this
        # service chose would look like your choice, and the backfill would
        # refuse to correct it later.
        #
        # `asins` rather than `item_ids`: the backfill writes that name, and one
        # field under two names is a field nothing can query.
        amazon = {
          "order_id" => order.order_id,
          "asins"    => [order.item_id].compact,
          "category" => attrs[:category],
          "source"   => "delivery_board",
        }.compact
        attrs[:metadata] = transaction.metadata.to_h.merge("amazon" => amazon)

        transaction.update!(attrs)
        stamp_event!(transaction, amazon)
      end

      # The same order number and ASINs onto the alert, so the purchase can be
      # traced from either side. Only the identifiers — the event owns its own
      # category and notes, and this must not touch them.
      #
      # Written straight to `data` rather than through ActionEventNotifier: the
      # notifier fires a :event Jil trigger, and stamping an id is not an event
      # worth waking every watch and automation for.
      def stamp_event!(transaction, amazon)
        event = transaction.action_event
        return if event.blank?

        facts = amazon.slice("order_id", "asins")
        return if event.data.to_h["amazon"] == facts

        event.update!(data: event.data.to_h.merge("amazon" => facts))
      end

      # The same rule the backfill used: blank, or still carrying the payee the
      # alert auto-filled. Anything typed by hand is left alone.
      def auto_filled?(transaction)
        current = transaction.display_memo
        current.to_s.strip.empty? || current.match?(/item|amazon|amzn/i)
      end
    end
  end
end
