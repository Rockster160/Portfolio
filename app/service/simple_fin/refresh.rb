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
      :accounts, :transactions, :created, :linked, :ambiguous, :transfers, :errors,
      keyword_init: true
    ) do
      def to_log
        "accounts=#{accounts} transactions=#{transactions} created=#{created} " \
          "linked=#{linked} ambiguous=#{ambiguous} transfers=#{transfers}"
      end
    end

    # `start_date`/`end_date` are for the historical backfill, which walks
    # windows that are nowhere near today. Everything else wants the default:
    # the last fortnight, open-ended at the recent side.
    def self.call(window_days: DEFAULT_WINDOW_DAYS, start_date: nil, end_date: nil)
      start_date ||= window_days.days.ago
      sync = ::SimpleFin::Sync.run!(start_date: start_date, end_date: end_date)
      # Both run unscoped on purpose: a backfilled row from 2024 has to be
      # offered the alerts and the counterparts it never got the chance to
      # match against.
      match = ::SimpleFin::EventMatcher.call
      transfers = ::SimpleFin::TransferDetector.call

      Result.new(
        accounts:     sync.accounts,
        transactions: sync.transactions,
        created:      sync.created,
        linked:       match.linked,
        ambiguous:    match.ambiguous,
        transfers:    transfers.paired,
        errors:       sync.errors,
      )
    end
  end
end
