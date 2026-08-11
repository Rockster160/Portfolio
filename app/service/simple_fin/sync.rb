module SimpleFin
  # Folds a /accounts payload into BankAccount + BankTransaction rows.
  #
  # Idempotent by design — SimpleFIN ids are stable, so re-syncing an
  # overlapping window updates in place rather than duplicating. That matters
  # because a transaction's `posted` timestamp and description can both change
  # after it first appears, while pending clears.
  class Sync
    Result = Struct.new(:accounts, :transactions, :errors, keyword_init: true) do
      def errors? = errors.present?
    end

    def self.call(payload) = new(payload).call

    # Fetches and folds in one step. Keyword args pass straight through to the
    # client, so a scheduled refresh can ask for balances only.
    def self.run!(**) = call(::SimpleFin::Client.accounts(**))

    def initialize(payload)
      @payload = payload || {}
      @transaction_count = 0
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

      Result.new(accounts: accounts.size, transactions: @transaction_count, errors: errors)
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

      ::Array.wrap(data["transactions"]).each { |row| upsert_transaction(account, row) }
    end

    def upsert_transaction(account, row)
      transaction = ::BankTransaction.find_or_initialize_by(simplefin_id: row["id"])
      transaction.assign_attributes(
        bank_account:  account,
        posted_at:     timestamp(row["posted"]),
        transacted_at: timestamp(row["transacted_at"]),
        amount_cents:  cents(row["amount"]),
        description:   row["description"],
        payee:         row["payee"],
        memo:          row["memo"],
        mcc:           row["mcc"],
        pending:       row["pending"].present?,
      )
      transaction.save!
      @transaction_count += 1
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
