module SimpleFin
  # Decides whether a just-arrived Chase alert is likely to move the figure the
  # dashboard shows, and if so starts a chase to go and fetch the new balance.
  #
  # The dashboard floors to the thousand ("18k"), so most charges change
  # nothing on screen and are not worth a request. The ones that matter are
  # the ones that tip the balance across a thousand boundary — at $2,034 a $35
  # charge turns a 2 into a 1, and until the next scheduled sync the dashboard
  # is confidently wrong by a whole unit.
  module BalanceWatch
    EVENT_NAME = "Transaction".freeze

    class << self
      # Returns true only when a chase was requested.
      # rubocop:disable Naming/PredicateMethod -- it enqueues; `?` would imply a query
      def consider(event)
        return false if event.blank? || event.name.to_s != EVENT_NAME
        # Already synced: if a bank row exists for this alert, SimpleFIN has
        # seen the charge and the balance it reported already accounts for it.
        return false if ::BankTransaction.exists?(action_event_id: event.id)

        account = ::SimpleFin::DashboardCache.primary
        return false if account.nil? || account.balance_cents.nil?
        return false if ::BankAccount.last4_from(event.data&.dig("account")) != account.last4

        cents = amount_cents(event)
        return false if cents.nil? || cents.zero?
        return false unless crosses_thousand?(account.balance_cents, cents)

        # Asks for a chase unconditionally. Whether one is already in flight is
        # Sidekiq's problem — the worker holds a uniqueness lock, so a second
        # request while one is queued is dropped there rather than tracked here.
        ::SimpleFinBalanceChaseWorker.start!
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # Treated as money LEAVING the account. The alerts store an unsigned
      # amount with no direction, and on a checking account the overwhelming
      # majority are charges. A deposit large enough to cross a boundary is
      # picked up by the scheduled sync within four hours instead — the cost
      # of being wrong here is lateness, not a wrong number.
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
