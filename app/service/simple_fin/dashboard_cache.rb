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
  #
  # It is built from AVAILABLE, not from the posted balance. The two differ by
  # whatever the bank has authorized and not yet posted, and that gap is real
  # money already spent: a $1,393.25 mortgage debit sat in `available` for
  # hours while `balance` still counted it as mine. Publishing the posted
  # balance meant the dashboard confidently showed money that was gone.
  #
  # The trade is the other direction: a deposit the bank is still holding
  # counts in `balance` before it counts in `available`, so the figure reads
  # low until the hold clears. Understating what you have is the safer error of
  # the two, and it corrects itself on the next sync.
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
        cents = available_cents
        return nil if cents.nil?

        amount = BigDecimal(cents) / 100
        published = amount.to_s("F")
        previous = user.caches.dig(CACHE_KEY, AMOUNT)
        user.caches.dig_set(CACHE_KEY, AMOUNT, published)

        if previous.to_s != published
          announce_change(previous, amount)
          publish!(user)
        end

        amount
      end

      # Writing the cache key moves nothing on screen by itself. Jil task 439
      # "Home Extras Cell" listens on `monitor::home_extras`, and IT is what
      # reads the key and broadcasts — so the cell only picked up a new balance
      # the next time the dashboard asked for the channel, which for a page
      # left open all day is never.
      #
      # Triggering the listener rather than broadcasting from here keeps the
      # Jil task the owner of what the dashboard displays, which is the whole
      # reason this writes a cache key instead of talking to the cell.
      # `auth:` is passed explicitly even though :trigger is the default, so the
      # data hash is not the trailing argument — a bare trailing hash here is
      # read as keyword arguments and raises.
      def publish!(user)
        ::Jil.trigger(user, :monitor, { channel: :home_extras, refresh: true }, auth: :trigger)
      rescue ::StandardError => e
        # The number is already stored and correct. A task that fails while
        # re-rendering the cell must not take a sync down with it.
        ::Rails.logger.warn("[SimpleFin::DashboardCache] home_extras refresh failed: #{e.message}")
      end

      # Everything the reported figure is made of. Unclassified accounts are
      # left out: a headline number should not rest on a guess about what an
      # account is, and the banking page already asks for the kind.
      #
      # So are hand-created accounts that carry no balance. The two closed Chase
      # cards are real credit accounts and are correctly classified as such, but
      # no institution reports them and none ever will — so their missing
      # balance is a permanent fact, not a sync that has not happened yet, and
      # letting it nil the total blanked the dashboard the moment they were
      # classified.
      #
      # Deliberately `simplefin_id IS NOT NULL OR balance_cents IS NOT NULL`
      # rather than just the former: a hand-created account that is given a
      # balance should count, and a SimpleFIN account that fails to report one
      # must still blank the figure. That second half is the behaviour worth
      # keeping — see `balance_cents`.
      def included_accounts
        scope = ::BankAccount.classified.where.not(kind: EXCLUDED_KINDS)
        scope.where("simplefin_id IS NOT NULL OR balance_cents IS NOT NULL").order(:id)
      end

      # The accounts that should have a balance and do not — i.e. exactly what
      # is blanking the figure. Empty when nothing is wrong.
      def missing_balance
        included_accounts.where(balance_cents: nil).to_a
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
        return false if account.simplefin_id.nil? && account.balance_cents.nil?

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
        cents = available_cents
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
