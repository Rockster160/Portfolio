module SimpleFin
  # Decides whether a just-arrived Chase alert leaves our estimate of the
  # balance far enough from the bank's own last figure to be worth a request,
  # and if so starts a chase to go and fetch a fresh one.
  #
  # The dashboard floors to the thousand ("9k"), so most charges change nothing
  # on screen and are not worth a request. The ones that matter are the ones
  # that tip the total across a thousand boundary — at $2,034 a $35 charge
  # turns a 2 into a 1.
  #
  # The test is DIVERGENCE, not the size of this one charge. It used to
  # subtract the charge from the reported figure and ask whether that crossed a
  # boundary. That stopped being the right question when the published number
  # became a projection: the row for this alert already exists by the time this
  # runs and is already counted, so the old sum subtracted it a second time,
  # and it ignored every other charge sitting unsettled alongside it. Comparing
  # the two published figures asks what actually matters — is what we are
  # showing a different number, at the resolution shown, from the last thing
  # the bank told us — and gets deposits right for free, where the old
  # direction-blind subtraction could only ever treat them as spending.
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

        return false unless diverged?

        # Asks for a chase unconditionally. Whether one is already in flight is
        # Sidekiq's problem — the worker holds a uniqueness lock, so a second
        # request while one is queued is dropped there rather than tracked here.
        ::SimpleFinBalanceChaseWorker.start!
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # Whether what the dashboard is showing and what the bank last reported
      # are different numbers AT THE RESOLUTION SHOWN. Both are floored the
      # same way `thousands` floors — integer division toward negative
      # infinity, so an overdraft reads one lower rather than one closer to
      # zero.
      #
      # False whenever either figure is unavailable: an account that has never
      # reported has nothing to project from, and there is no divergence to
      # measure against a number that does not exist.
      def diverged?
        reported = ::SimpleFin::DashboardCache.available_cents
        projected = ::SimpleFin::DashboardCache.projected_cents
        return false if reported.nil? || projected.nil?

        reported / 100_000 != projected / 100_000
      end
    end
  end
end
