module SimpleFin
  # Links a SimpleFIN bank transaction to the Chase-alert ActionEvent that
  # already described the same purchase.
  #
  # The two feeds arrive in a fixed order: the alert email fires at purchase
  # time and becomes a categorised ActionEvent, then SimpleFIN reports the same
  # charge up to a day later. So this always runs in one direction — new bank
  # rows looking backwards for the event that beat them here.
  #
  # A match needs all three of: same account (by trailing four digits, the only
  # identifier the older events carry), same absolute amount to the cent, and a
  # timestamp inside WINDOW. Anything that lands on two candidates is left
  # alone rather than guessed at — a wrong link silently attributes one
  # purchase's category and notes to another.
  class EventMatcher
    # The alert timestamps the purchase; SimpleFIN timestamps when it cleared.
    # Weekends and card holds put a few days between them.
    WINDOW = 5.days
    EVENT_NAME = "Transaction".freeze

    Result = Struct.new(:linked, :ambiguous, :unmatched, keyword_init: true)

    def self.call(scope=::BankTransaction.unlinked) = new(scope).call

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
      candidates = candidates.select { |event| within_window?(event, transaction) }

      case candidates.size
      when 0 then @unmatched += 1
      when 1
        transaction.update!(action_event: candidates.first)
        claimed << candidates.first.id
        @linked += 1
      else @ambiguous += 1
      end
    end

    def within_window?(event, transaction)
      occurred = transaction.occurred_at
      return false if occurred.blank? || event.timestamp.blank?

      (event.timestamp - occurred).abs <= WINDOW
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
        [::BankAccount.last4_from(event.data&.dig("account")), event_amount_cents(event)]
      }
    end

    # Events store the amount unsigned; bank rows are signed. Compared on
    # absolute value, so a refund does not match its own charge by sign alone.
    def event_amount_cents(event)
      raw = event.data&.dig("amount")
      return nil if raw.blank?

      (BigDecimal(raw.to_s) * 100).round.abs
    rescue ArgumentError
      nil
    end
  end
end
