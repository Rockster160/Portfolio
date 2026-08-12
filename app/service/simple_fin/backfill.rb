module SimpleFin
  # Walks backwards through history one window at a time, until there is
  # nothing older left to fetch.
  #
  # "Give me everything" is not a request that can be made: the Bridge caps a
  # single /accounts range at 90 days and budgets 24 requests a day. Years of
  # history therefore have to be collected a window at a time.
  #
  # Scheduled every three hours — eight a day, which alongside the six
  # scheduled syncs and up to four chases is 18 of the 24. Spread rather than
  # bursted because the quota replenishes through the day. Safe to call by hand
  # on top of that; the leeway the Bridge allows for setup covers it.
  #
  # The cursor is the oldest date already asked for, not the oldest row held.
  # Those differ whenever a window comes back empty, and using the oldest row
  # would re-request the same empty window every day forever without ever
  # moving or reporting that it was finished.
  module Backfill
    STORAGE_KEY = "simplefin_backfill".freeze

    # 87 + 3 = 90, exactly the cap. The overlap deliberately re-asks for three
    # days that are already covered: a transaction can post days after it was
    # made, so it can appear inside a window that had already been fetched
    # before it existed. Exactly-adjacent windows would step straight over it
    # and nothing downstream would ever notice the hole.
    CHUNK_DAYS = 87
    OVERLAP_DAYS = 3

    # Two empty windows in a row, not one. An account can genuinely have a
    # quiet quarter, and stopping at the first would abandon everything older
    # than it.
    EMPTY_RUNS_TO_STOP = 2

    # A backstop, not a target. Nothing here predates it, and without a floor
    # an arithmetic slip in the cursor would walk toward 1970 one request a day
    # with nothing to stop it.
    FLOOR = ::Time.utc(2015, 1, 1).freeze

    Result = Struct.new(:status, :start_date, :end_date, :created, :cursor, keyword_init: true) do
      def to_log
        return status.to_s if start_date.nil?

        "#{status} #{start_date.to_date}..#{end_date.to_date} created=#{created}"
      end
    end

    Progress = Struct.new(
      :cursor, :done, :oldest_row, :newest_row, :windows_remaining, :percent,
      keyword_init: true
    ) do
      # Nothing has synced yet, so there is no walk to report on.
      def idle? = cursor.nil?
    end

    class << self
      def call
        return result(:not_configured) unless ::SimpleFin::Client.configured?

        state = load_state
        return result(:done, cursor: state[:cursor]) if state[:done]

        cursor = oldest_asked(state)
        # Nothing has ever synced, so there is no anchor to walk back from. The
        # scheduled sync will lay one down.
        return result(:idle) if cursor.nil?
        return stop!(state, cursor) if cursor <= FLOOR

        end_date = cursor + OVERLAP_DAYS.days
        start_date = [cursor - CHUNK_DAYS.days, FLOOR].max

        refresh = ::SimpleFin::Refresh.call(start_date: start_date, end_date: end_date)
        advance!(state, start_date, refresh.created.to_i)

        result(
          :fetched,
          start_date: start_date, end_date: end_date,
          created: refresh.created.to_i, cursor: start_date
        )
      end

      # Starts the walk over. The rows already collected are untouched — a
      # re-walk re-upserts them in place, which is the whole reason the sync is
      # idempotent.
      def reset!
        ::DataStorage[STORAGE_KEY] = {}
      end

      def state
        load_state
      end

      # What the walk has covered, for the banking page. `windows_remaining` is
      # an UPPER bound and says so — it counts to the 2015 floor, while the
      # walk stops as soon as two windows come back empty, which for most
      # accounts is far sooner.
      def progress
        current = load_state
        cursor = oldest_asked(current)
        newest = ::BankTransaction.maximum(:occurred_at)

        Progress.new(
          cursor:            cursor,
          done:              current[:done],
          oldest_row:        ::BankTransaction.minimum(:occurred_at),
          newest_row:        newest,
          windows_remaining: windows_remaining(cursor, current[:done]),
          percent:           percent_covered(cursor, newest, current[:done]),
        )
      end

      private

      # The stored cursor, except when a row older than it has turned up by
      # some other route — then that row is the honest starting point. Takes
      # the older of the two, so the walk can only ever extend backwards.
      # `occurred_at`, not `posted_at` — the same column the table shows, the
      # search reads and the walk reports against. Anchoring on posted_at made
      # the progress note quote a different date from the one beside it, and
      # for a date-only row the two are a whole calendar day apart. It also
      # errs the safe way: occurred_at is never later than posted_at, so the
      # anchor can only reach further back, never skip.
      def oldest_asked(state)
        [state[:cursor], ::BankTransaction.minimum(:occurred_at)].compact.min
      end

      # How much of the fetchable span is held: everything between the newest
      # transaction and the floor is the whole bar.
      #
      # Full when the walk finishes, wherever it finished. "Complete" means
      # there is nothing older to fetch, not that a particular date was
      # reached — so a walk that runs dry in 2019 fills the bar, and the bar
      # does not have to explain itself to be true.
      def percent_covered(cursor, newest, done)
        return 0 if cursor.nil? || newest.nil?
        return 100 if done

        total = (newest - FLOOR).to_f
        return 100 if total <= 0

        (((newest - cursor) / total) * 100).clamp(0, 100).round
      end

      def windows_remaining(cursor, done)
        return 0 if done || cursor.nil? || cursor <= FLOOR

        ((cursor - FLOOR) / CHUNK_DAYS.days).ceil
      end

      def advance!(state, cursor, created)
        empty_runs = created.zero? ? state[:empty_runs] + 1 : 0
        save_state(
          cursor:     cursor,
          empty_runs: empty_runs,
          done:       empty_runs >= EMPTY_RUNS_TO_STOP || cursor <= FLOOR,
        )
      end

      def stop!(state, cursor)
        save_state(cursor: cursor, empty_runs: state[:empty_runs], done: true)
        result(:done, cursor: cursor)
      end

      def load_state
        raw = ::DataStorage[STORAGE_KEY]
        raw = {} unless raw.is_a?(::Hash)
        data = raw.symbolize_keys

        {
          cursor:     parse_time(data[:cursor]),
          empty_runs: data[:empty_runs].to_i,
          done:       ::ActiveModel::Type::Boolean.new.cast(data[:done]).present?,
        }
      end

      def save_state(cursor:, empty_runs:, done:)
        ::DataStorage[STORAGE_KEY] = {
          cursor:      cursor.utc.iso8601,
          empty_runs:  empty_runs,
          done:        done,
          last_run_at: ::Time.current.utc.iso8601,
        }
      end

      # A cursor that will not parse is treated as absent rather than as a
      # reason to fail — the oldest row is a perfectly good fallback anchor.
      def parse_time(value)
        return nil if value.blank?

        ::Time.zone.parse(value.to_s)&.utc
      rescue ::ArgumentError
        nil
      end

      def result(status, **)
        Result.new(status: status, **)
      end
    end
  end
end
