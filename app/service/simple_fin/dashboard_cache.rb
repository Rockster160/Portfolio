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
        previous = user.caches.dig(CACHE_KEY, AMOUNT)
        user.caches.dig_set(CACHE_KEY, AMOUNT, amount.to_s("F"))
        announce_change(previous, amount)
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
      # Announced from here rather than from either worker, because this is the
      # one place the published figure actually changes — the scheduled sync
      # and the chase job both land here and neither has to remember.
      #
      # Fires on the DISPLAYED figure, not the raw balance: almost every sync
      # moves the balance by some amount, and a notification on each of those
      # would be constant noise. It says nothing about the amount or the value,
      # only that the number on the dashboard is not what it was.
      def announce_change(previous_raw, amount)
        # Nothing to compare against on the very first write, and "it changed"
        # is meaningless when there was no previous number.
        return if previous_raw.blank?

        before = (BigDecimal(previous_raw.to_s) / 1000).floor
        after = (amount / 1000).floor
        return if before == after

        ::Jarvis.say("Checking balance changed.")
      rescue ::ArgumentError
        # A previous value that will not parse is not worth failing a sync over.
        nil
      end

      def thousands(account=primary)
        return nil if account.nil? || account.balance_cents.nil?

        account.balance_cents / 100_000
      end
    end
  end
end
