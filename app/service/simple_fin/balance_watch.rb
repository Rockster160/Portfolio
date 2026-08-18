module SimpleFin
  # Decides whether a just-arrived Chase alert is likely to move the figure the
  # dashboard shows, and if so starts a chase to go and fetch the new balance.
  #
  # The dashboard floors to the thousand ("9k"), so most charges change nothing
  # on screen and are not worth a request. The ones that matter are the ones
  # that tip the total across a thousand boundary — at $2,034 a $35 charge
  # turns a 2 into a 1, and until the next scheduled sync the dashboard is
  # confidently wrong by a whole unit.
  module BalanceWatch
    EVENT_NAME = "Transaction".freeze

    class << self
      # Returns true only when a chase was requested.
      # rubocop:disable Naming/PredicateMethod -- it enqueues; `?` would imply a query
      def consider(event)
        return false if event.blank? || event.name.to_s != EVENT_NAME
        # Already synced: if SimpleFIN has reported this charge, the balance it
        # sent alongside already accounts for it and there is nothing to chase.
        #
        # BANK-CONFIRMED, not merely present. Every alert now lands a row of its
        # own the moment it arrives — and it arrives before this runs — so a
        # bare existence check answers "did we just create it", which is always
        # yes, and no chase would ever fire again.
        return false if ::BankTransaction.bank_confirmed.exists?(action_event_id: event.id)

        # Any account in the reported figure, not just checking — the number
        # is cumulative now, so a card charge moves it exactly as a checking
        # charge does.
        last4 = ::BankAccount.last4_from(event.data&.dig("account"))
        return false if last4.blank?
        return false unless ::SimpleFin::DashboardCache.included_accounts.exists?(last4: last4)

        # The published figure, which is the available total — the same number
        # `thousands` floors and the chase worker watches. Measuring the
        # crossing against the posted balance would test a boundary the
        # dashboard never shows.
        total = ::SimpleFin::DashboardCache.available_cents
        return false if total.nil?

        cents = amount_cents(event)
        return false if cents.nil? || cents.zero?
        return false unless crosses_thousand?(total, cents)

        # Asks for a chase unconditionally. Whether one is already in flight is
        # Sidekiq's problem — the worker holds a uniqueness lock, so a second
        # request while one is queued is dropped there rather than tracked here.
        ::SimpleFinBalanceChaseWorker.start!
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # Treated as money LEAVING the total. The alerts store an unsigned amount
      # with no direction, and the overwhelming majority are charges — which
      # pull the cumulative figure down whether they land on checking or on a
      # card, since a card charge deepens what is owed. A deposit large enough
      # to cross a boundary is picked up by the scheduled sync within four
      # hours instead — the cost of being wrong here is lateness, not a wrong
      # number.
      def crosses_thousand?(balance_cents, spend_cents)
        before = balance_cents / 100_000
        after = (balance_cents - spend_cents) / 100_000
        before != after
      end

      private

      def amount_cents(event)
        raw = event.data&.dig("amount")
        return nil if raw.blank?

        (BigDecimal(raw.to_s) * 100).round.abs
      rescue ArgumentError
        nil
      end
    end
  end
end
