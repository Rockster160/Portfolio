module SimpleFin
  # Links a SimpleFIN bank transaction to the Chase-alert ActionEvent that
  # describes the same purchase.
  #
  # Both directions are supported, because both happen:
  #
  #   bank row -> event   the usual case. The alert fires at purchase time and
  #                       SimpleFIN reports the charge up to a day later, so a
  #                       new bank row looks backwards. `call`.
  #   event -> bank row   the inverted case. A charge synced before its alert
  #                       was categorized, an event edited or created by hand
  #                       afterwards, or any backfill. `link_event`, driven
  #                       from ActionEventNotifier so every creation path is
  #                       covered.
  #
  # A match needs all three of: same account (by trailing four digits, the only
  # identifier the older events carry), same absolute amount to the cent, and a
  # timestamp inside WINDOW. Anything with two candidates is left alone rather
  # than guessed at — a wrong link silently attributes one purchase's category
  # and notes to another, and it is invisible once done.
  class EventMatcher
    # The alert timestamps the purchase; SimpleFIN timestamps when it cleared.
    # Weekends and card holds put a few days between them.
    WINDOW = 5.days
    EVENT_NAME = "Transaction".freeze

    Result = Struct.new(:linked, :ambiguous, :unmatched, keyword_init: true)

    class << self
      def call(scope=matchable) = new(scope).call

      # Unlinked rows that could actually find something.
      #
      # A bank row from before the first Chase alert has nothing it can ever
      # match, and the historical backfill produces years of them. Left in the
      # default scope they would be re-examined on every sync — fourteen times
      # a day, forever — to reach the same answer, and the scan grows with the
      # backfill rather than with the work.
      #
      # Derived from the data rather than configured, so it widens by itself
      # if older alerts ever appear.
      #
      # Filtered on `posted_at` because `occurred_at` is a Ruby fallback, not a
      # column. That is safe in the only direction that matters: a row is
      # matched on `transacted_at`, which never runs later than `posted_at`, so
      # nothing inside the window can sit outside this filter.
      def matchable
        earliest = ::ActionEvent.where(name: EVENT_NAME).minimum(:timestamp)
        return ::BankTransaction.unlinked if earliest.nil?

        ::BankTransaction.unlinked.where(posted_at: (earliest - WINDOW)..)
      end

      # Reverse direction, for one event. Returns the transaction it linked, or
      # nil. Idempotent and safe to call on every event: it exits immediately
      # for anything that is not a transaction.
      def link_event(event)
        return nil if event.blank? || event.name.to_s != EVENT_NAME
        return nil if ::BankTransaction.exists?(action_event_id: event.id)

        cents = event_amount_cents(event)
        return nil if cents.nil? || event.timestamp.blank?

        last4 = ::BankAccount.last4_from(event.data&.dig("account"))
        candidates = (
          if last4.present?
            candidates_for(last4, cents)
          else
            unattributed_candidates_for(event)
          end
        )
        candidates = candidates.select { |row| within_window?(event, row) }
        return nil unless candidates.one?

        candidates.first.tap { |row| attach!(row, event) }
      end

      # The link and the category land together, in both directions. Attaching
      # an event without copying what it says would leave the row's category
      # depending on which way round the match happened — a bank row matched by
      # `call` would stay blank while the same row matched by `link_event` came
      # out categorized.
      def attach!(transaction, event)
        transaction.update!(
          action_event: event,
          category:     ::SimpleFin::EventTransaction.category_for(event) || transaction.category,
        )
      end

      # Events store the amount unsigned; bank rows are signed. Compared on
      # absolute value, so a refund does not match its own charge by sign.
      def event_amount_cents(event)
        raw = event.data&.dig("amount")
        return nil if raw.blank?

        (BigDecimal(raw.to_s) * 100).round.abs
      rescue ArgumentError
        nil
      end

      def within_window?(event, transaction)
        occurred = transaction.occurred_at
        return false if occurred.blank? || event.timestamp.blank?

        (event.timestamp - occurred).abs <= WINDOW
      end

      private

      def candidates_for(last4, cents)
        accounts = ::BankAccount.where(last4: last4).select(:id)
        scope = ::BankTransaction.unlinked.where(bank_account_id: accounts)
        scope.where(amount_cents: [cents, -cents]).to_a
      end

      # 433 alerts come from a format that names no account, so account is not
      # available to narrow on and every account has to be searched. Two things
      # make that safe enough to do:
      #
      #   * SIGNED amounts, not magnitude. Without an account to separate them,
      #     magnitude would let a refund match the charge it reverses.
      #   * the same `one?` rule as everywhere else — with a weaker key, more
      #     of these land ambiguous, and ambiguous means a second row rather
      #     than a guess. A duplicate is visible on the page and mergeable; a
      #     wrong attachment moves one purchase's category onto another and
      #     nothing ever shows that it happened.
      def unattributed_candidates_for(event)
        cents = ::SimpleFin::EventTransaction.amount_cents_for(event)
        return [] if cents.nil?

        ::BankTransaction.unlinked.where(amount_cents: cents).to_a
      end
    end

    def initialize(scope)
      @scope = scope
      @linked = 0
      @ambiguous = 0
      @unmatched = 0
    end

    def call
      transactions = @scope.includes(:bank_account).to_a
      return empty_result if transactions.empty?

      index = event_index(transactions)
      claimed = ::BankTransaction.linked.pluck(:action_event_id).to_set

      transactions.each { |transaction| match(transaction, index, claimed) }

      Result.new(linked: @linked, ambiguous: @ambiguous, unmatched: @unmatched)
    end

    private

    def empty_result
      Result.new(linked: 0, ambiguous: 0, unmatched: 0)
    end

    def match(transaction, index, claimed)
      key = [transaction.bank_account&.last4, transaction.amount_cents.abs]
      return (@unmatched += 1) if key.first.blank?

      candidates = index[key].to_a.reject { |event| claimed.include?(event.id) }
      candidates = candidates.select { |event|
        self.class.within_window?(event, transaction)
      }

      case candidates.size
      when 0 then @unmatched += 1
      when 1
        self.class.attach!(transaction, candidates.first)
        claimed << candidates.first.id
        @linked += 1
      else @ambiguous += 1
      end
    end

    # One query for every candidate event in range, then matched in memory.
    # Per-transaction lookups would be hundreds of round trips for a backfill.
    def event_index(transactions)
      times = transactions.filter_map(&:occurred_at)
      return {} if times.empty?

      events = ::ActionEvent.where(
        name:      EVENT_NAME,
        timestamp: (times.min - WINDOW)..(times.max + WINDOW),
      )

      events.group_by { |event|
        [
          ::BankAccount.last4_from(event.data&.dig("account")),
          self.class.event_amount_cents(event),
        ]
      }
    end
  end
end
