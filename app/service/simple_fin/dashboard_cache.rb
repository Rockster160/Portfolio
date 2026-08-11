module SimpleFin
  # Publishes the headline balance into the `bank` user cache.
  #
  # The dashboard's home cell does NOT read BankAccount. Jil task 439 "Home
  # Extras Cell" reads `Global.get_cache("bank", "amount")` and broadcasts it,
  # and home.js renders whatever that produced. That key had no writer, so the
  # cell has been showing "?" — the fix is to give it one, not to rewire the
  # cell. Keeps the Jil task as the owner of what the dashboard displays.
  #
  # Writes only the primary checking account. If none is designated the key is
  # left completely alone: showing a card or mortgage balance in the slot
  # labeled with a bank icon would be worse than showing nothing, and the
  # cell already renders "?" gracefully.
  module DashboardCache
    CACHE_KEY = :bank
    AMOUNT = :amount

    class << self
      def refresh!(user: ::User.me)
        account = primary
        return nil if account.nil? || account.balance_cents.nil?

        amount = account.balance
        user.caches.dig_set(CACHE_KEY, AMOUNT, amount.to_s("F"))
        amount
      end

      # Lowest id breaks a tie so the value cannot flip between syncs if a
      # second checking account is ever added.
      def primary
        ::BankAccount.checking.order(:id).first
      end

      # The figure the dashboard actually renders — home.js floors to the
      # thousand and prints "18k". That flooring is why a small charge can be
      # invisible for hours and then move the display by a whole unit, and it
      # is what SimpleFinBalanceChaseWorker watches for a change in.
      #
      # Integer division floors toward negative infinity in Ruby, which is the
      # behavior wanted here: an overdrawn account reads one lower, not one
      # closer to zero.
      def thousands(account=primary)
        return nil if account.nil? || account.balance_cents.nil?

        account.balance_cents / 100_000
      end
    end
  end
end
