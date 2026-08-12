module SimpleFin
  # Walks the 2,563 historical `Transaction` ActionEvents and gives each one a
  # bank_transactions row, a batch at a time.
  #
  # Not a migration and not one long loop. Every event costs several queries —
  # `EventTransaction.sync` looks for a bank row already holding the purchase
  # before it creates one — so the whole set is minutes of work holding a
  # connection, in a migration that would block a deploy, and any failure part
  # way through leaves no record of how far it got.
  #
  # Instead: a cursor, a bounded batch, and a worker that re-enqueues itself
  # until there is nothing left. Interrupting it costs one batch.
  #
  # The cursor is an ActionEvent ID, and it only ever moves forward. Selecting
  # "events with no row" instead would be self-describing and need no state —
  # but an event that cannot be projected at all would be picked up again on
  # every pass, forever, and the walk would never finish.
  module EventBackfill
    STORAGE_KEY = "simplefin_event_backfill".freeze
    EVENT_NAME = ::SimpleFin::EventMatcher::EVENT_NAME

    # Small enough that a batch is a second or two and an interrupt is cheap;
    # large enough that 2,563 events is ten passes rather than a hundred.
    BATCH = 250

    Result = Struct.new(
      :status, :examined, :created, :linked, :skipped, :cursor, keyword_init: true
    ) do
      def done? = status == :done

      def to_log
        return status.to_s if examined.to_i.zero?

        "#{status} examined=#{examined} created=#{created} linked=#{linked} skipped=#{skipped}"
      end
    end

    Progress = Struct.new(
      :cursor, :done, :projected, :total, :remaining, :percent, keyword_init: true
    ) do
      def idle? = total.to_i.zero?
    end

    class << self
      # One batch. Returns :done when there is nothing after the cursor, which
      # is what tells the worker to stop re-enqueueing.
      def call(limit: BATCH)
        state = load_state
        return result(:done, cursor: state[:cursor]) if state[:done]

        events = batch(state[:cursor], limit)
        return finish!(state) if events.empty?

        counts = project(events)
        save_state(cursor: events.last.id, done: false)

        result(
          :ran,
          examined: events.size, created: counts[:created],
          linked: counts[:linked], skipped: counts[:skipped], cursor: events.last.id
        )
      end

      # Runs the whole thing here and now, for a console. The worker is the
      # normal path; this is for when you want to watch it finish.
      def call_all(limit: BATCH)
        totals = Hash.new(0)
        loop do
          outcome = call(limit: limit)
          break if outcome.done?

          [:examined, :created, :linked, :skipped].each { |key| totals[key] += outcome[key].to_i }
        end
        totals
      end

      def reset!
        ::DataStorage[STORAGE_KEY] = {}
      end

      def state
        load_state
      end

      # Counted rather than stored, so it stays true even if the walk is reset
      # or an event is added behind the cursor.
      def progress
        current = load_state
        total = events.count
        projected = ::BankTransaction.where(action_event_id: events.select(:id)).count

        Progress.new(
          cursor:    current[:cursor],
          done:      current[:done],
          projected: projected,
          total:     total,
          remaining: [total - projected, 0].max,
          percent:   total.positive? ? ((projected.to_f / total) * 100).round : 0,
        )
      end

      def events
        ::ActionEvent.where(name: EVENT_NAME)
      end

      private

      def batch(cursor, limit)
        scope = events.order(:id).limit(limit)
        scope = scope.where(id: (cursor + 1)..) if cursor.present?
        scope.to_a
      end

      # `sync` is idempotent, so an event already holding a row is cheap to
      # re-examine — but skipping the ones we can see are done keeps a re-run
      # from re-querying for a match that has already been made.
      def project(events)
        held = ::BankTransaction.where(action_event_id: events.map(&:id)).pluck(:action_event_id)
        held = held.to_set
        counts = Hash.new(0)

        events.each { |event|
          next counts[:skipped] += 1 if held.include?(event.id)

          before = ::BankTransaction.count
          row = ::SimpleFin::EventTransaction.sync(event)

          key = (
            if row.nil?
              :skipped
            elsif ::BankTransaction.count > before
              :created
            else
              :linked
            end
          )
          counts[key] += 1
        }

        counts
      end

      def finish!(state)
        save_state(cursor: state[:cursor], done: true)
        result(:done, cursor: state[:cursor])
      end

      def load_state
        raw = ::DataStorage[STORAGE_KEY]
        raw = {} unless raw.is_a?(::Hash)
        data = raw.symbolize_keys

        {
          cursor: data[:cursor].presence&.to_i,
          done:   ::ActiveModel::Type::Boolean.new.cast(data[:done]).present?,
        }
      end

      def save_state(cursor:, done:)
        ::DataStorage[STORAGE_KEY] = {
          cursor:      cursor,
          done:        done,
          last_run_at: ::Time.current.utc.iso8601,
        }
      end

      def result(status, **)
        Result.new(status: status, **)
      end
    end
  end
end
