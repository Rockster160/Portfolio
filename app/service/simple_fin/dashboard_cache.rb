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
  # labelled with a bank icon would be worse than showing nothing, and the
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
    end
  end
end
