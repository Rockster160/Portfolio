module SimpleFin
  # The whole "bring everything up to date" sequence, in the order it has to
  # happen: pull, then link the alerts to what arrived, then pair transfers —
  # which can only run once both halves of a movement exist.
  #
  # One call is one request against the Bridge's ~24/day budget, so every
  # caller should have a reason.
  module Refresh
    DEFAULT_WINDOW_DAYS = 14

    Result = Struct.new(
      :accounts, :transactions, :linked, :ambiguous, :transfers, :errors,
      keyword_init: true
    ) do
      def to_log
        "accounts=#{accounts} transactions=#{transactions} linked=#{linked} " \
          "ambiguous=#{ambiguous} transfers=#{transfers}"
      end
    end

    def self.call(window_days: DEFAULT_WINDOW_DAYS)
      sync = ::SimpleFin::Sync.run!(start_date: window_days.days.ago)
      match = ::SimpleFin::EventMatcher.call
      transfers = ::SimpleFin::TransferDetector.call

      Result.new(
        accounts:     sync.accounts,
        transactions: sync.transactions,
        linked:       match.linked,
        ambiguous:    match.ambiguous,
        transfers:    transfers.paired,
        errors:       sync.errors,
      )
    end
  end
end
