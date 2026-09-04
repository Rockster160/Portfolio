module SimpleFin
  # Folds a /accounts payload into BankAccount + BankTransaction rows.
  #
  # Idempotent by design — SimpleFIN ids are stable, so re-syncing an
  # overlapping window updates in place rather than duplicating. That matters
  # because a transaction's `posted` timestamp and description can both change
  # after it first appears, while pending clears.
  class Sync
    # `transactions` counts everything the payload carried; `created` counts
    # only the rows that did not already exist. The backfill needs the
    # difference — re-fetching an overlapping window reports plenty of
    # transactions and no new history, and it is `created` that says whether
    # there is anything older left to find.
    Result = Struct.new(:accounts, :transactions, :created, :errors, keyword_init: true) do
      def errors? = errors.present?
    end

    def self.call(payload) = new(payload).call

    # Fetches and folds in one step. Keyword args pass straight through to the
    # client, so a scheduled refresh can ask for balances only.
    def self.run!(**) = call(::SimpleFin::Client.accounts(**))

    def initialize(payload)
      @payload = payload || {}
      @transaction_count = 0
      @created_count = 0
    end

    def call
      accounts = ::Array.wrap(@payload["accounts"])
      accounts.each { |data| upsert_account(data) }

      errors = ::Array.wrap(@payload["errlist"])
      # A 200 with a non-empty errlist means some institution did not refresh.
      # Its accounts still come back, carrying their previous balance and an
      # unchanged balance-date — which is why balance_date is stored verbatim
      # rather than stamped with the sync time.
      if errors.present?
        ::Rails.logger.warn("[SimpleFin::Sync] #{errors.size} upstream error(s): #{errors.inspect}")
      end

      # Kept in lockstep with the rows deliberately — a dashboard reading a
      # balance the tables no longer agree with is the failure worth avoiding.
      ::SimpleFin::DashboardCache.refresh!
      # And the spending bars, for the same reason: the rows this sync just
      # wrote are what they are summed from.
      ::SpendingHealth.refresh!

      Result.new(
        accounts:     accounts.size,
        transactions: @transaction_count,
        created:      @created_count,
        errors:       errors,
      )
    end

    private

    def upsert_account(data)
      account = ::BankAccount.find_or_initialize_by(simplefin_id: data["id"])
      # `kind` is deliberately absent: it is set by hand and a resync must not
      # clobber it.
      account.assign_attributes(
        conn_id:                 data["conn_id"],
        name:                    data["name"],
        last4:                   ::BankAccount.last4_from(data["name"]),
        currency:                data["currency"].presence || "USD",
        balance_cents:           cents(data["balance"]),
        available_balance_cents: cents(data["available-balance"]),
        balance_date:            timestamp(data["balance-date"]),
        last_synced_at:          ::Time.current,
      )
      account.save!
      # Written here rather than on a cron: the balance is only knowable at the
      # moment it arrives, and a separate schedule could miss a day outright.
      # A day missed is a day lost — the Bridge will re-serve transactions but
      # never a past balance.
      ::BankBalanceSnapshot.capture!(account)

      ::Array.wrap(data["transactions"]).each { |row| upsert_transaction(account, row) }
    end

    def upsert_transaction(account, row)
      transaction = ::BankTransaction.find_or_initialize_by(simplefin_id: row["id"])
      # A Chase alert may already have landed this purchase, minutes after it
      # was made and up to a day before the bank cleared it. That row is the
      # same transaction, carrying the category it was given at the time, so
      # the bank's version merges INTO it rather than appearing beside it.
      transaction = adopt(account, row) || transaction if transaction.new_record?
      created = transaction.new_record?
      transaction.assign_attributes(
        # Set here rather than left to find_or_initialize_by, because an
        # adopted row was found by other means and still has none.
        simplefin_id:  row["id"],
        bank_account:  account,
        posted_at:     timestamp(row["posted"]),
        transacted_at: timestamp(row["transacted_at"]),
        amount_cents:  cents(row["amount"]),
        description:   row["description"],
        # The bank's name for the merchant wins, but not a blank one — an
        # adopted row already carries the name the alert gave it.
        payee:         row["payee"].presence || transaction.payee,
        memo:          row["memo"],
        mcc:           row["mcc"],
        pending:       row["pending"].present?,
      )
      transaction.save!
      # Only for a row the bank has just told us about. An Amazon charge that
      # matches something on the delivery board picks up its order number, item
      # id, item name and a category better than "shopping" — the same three
      # things the order-history backfill wrote, by the same rules.
      ::SimpleFin::AmazonEnrichment.apply(transaction) if created
      @transaction_count += 1
      @created_count += 1 if created
    end

    # Matched on the transacted timestamp when the payload carries one, since
    # that is the same instant the alert fired on. `posted` can trail it by
    # days, which would push a genuine pair outside the merge window.
    def adopt(account, row)
      ::SimpleFin::EventTransaction.claim(
        bank_account: account,
        amount_cents: cents(row["amount"]),
        occurred_at:  timestamp(row["transacted_at"]) || timestamp(row["posted"]),
      )
    end

    # Amounts arrive as numeric strings. BigDecimal, never to_f — a float
    # round-trip on "337183.97" is exactly how a mortgage ends up off by a
    # cent.
    def cents(value)
      return nil if value.blank?

      (BigDecimal(value.to_s) * 100).round
    end

    def timestamp(unix)
      return nil if unix.nil?

      ::Time.at(unix.to_i).utc
    end
  end
end
