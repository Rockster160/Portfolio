module SimpleFin
  # Publishes the headline balance into the `bank` user cache.
  #
  # The dashboard's home cell does NOT read BankAccount. Jil task 439 "Home
  # Extras Cell" reads `Global.get_cache("bank", "amount")` and broadcasts it,
  # and home.js renders whatever that produced. That key had no writer, so the
  # cell has been showing "?" — the fix is to give it one, not to rewire the
  # cell. Keeps the Jil task as the owner of what the dashboard displays.
  #
  # The figure is CUMULATIVE: checking plus savings plus investments, minus
  # what is owed on the cards. That is the number that answers "what do I
  # actually have", where the checking balance on its own reads high by
  # whatever is sitting unpaid on a card.
  module DashboardCache
    CACHE_KEY = :bank
    AMOUNT = :amount

    # A mortgage is secured against a house and is two orders of magnitude
    # larger than everything else — folding it in turns the dashboard into a
    # large negative number that barely moves, which is not what the slot is
    # for. Any loan behaves the same way, so this excludes the kind rather than
    # the one account.
    EXCLUDED_KINDS = [:loan].freeze

    class << self
      def refresh!(user: ::User.me)
        cents = balance_cents
        return nil if cents.nil?

        amount = BigDecimal(cents) / 100
        previous = user.caches.dig(CACHE_KEY, AMOUNT)
        user.caches.dig_set(CACHE_KEY, AMOUNT, amount.to_s("F"))
        announce_change(previous, amount)
        amount
      end

      # Everything the reported figure is made of. Unclassified accounts are
      # left out: a headline number should not rest on a guess about what an
      # account is, and the banking page already asks for the kind.
      def included_accounts
        ::BankAccount.classified.where.not(kind: EXCLUDED_KINDS).order(:id)
      end

      # Nil rather than a partial sum when an account has no balance yet. A
      # total that silently omits one account is a wrong number, and the cell
      # renders "?" perfectly well.
      def balance_cents
        accounts = included_accounts.to_a
        return nil if accounts.empty? || accounts.any? { |account| account.balance_cents.nil? }

        accounts.sum(&:balance_cents)
      end

      # The same total, in available terms: the institution's available figure
      # where it reports one, and the balance where it does not. Differs from
      # `balance_cents` by whatever is authorized but not yet posted, which is
      # the whole reason a bank publishes two numbers.
      def available_cents
        accounts = included_accounts.to_a
        return nil if accounts.empty? || accounts.any? { |account| account.spendable_cents.nil? }

        accounts.sum(&:spendable_cents)
      end

      # Whether this account is part of the reported figure — what the banking
      # page marks its rows with.
      def included?(account)
        return false if account.nil? || account.unknown?

        EXCLUDED_KINDS.exclude?(account.kind&.to_sym)
      end

      # The figure the dashboard actually renders — home.js floors to the
      # thousand and prints "9k". That flooring is why a small charge can be
      # invisible for hours and then move the display by a whole unit, and it
      # is what SimpleFinBalanceChaseWorker watches for a change in.
      #
      # Integer division floors toward negative infinity in Ruby, which is the
      # behavior wanted here: an overdrawn total reads one lower, not one
      # closer to zero.
      def thousands
        cents = balance_cents
        return nil if cents.nil?

        cents / 100_000
      end

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

        ::Jarvis.say("Bank balance changed.")
      rescue ::ArgumentError
        # A previous value that will not parse is not worth failing a sync over.
        nil
      end
    end
  end
end
