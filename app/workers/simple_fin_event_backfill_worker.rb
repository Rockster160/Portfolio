class SimpleFinEventBackfillWorker
  include Sidekiq::Worker

  # Same shape as SimpleFinBalanceChaseWorker, and for the same reason: this
  # worker re-enqueues itself from inside `perform`, so the lock has to be
  # released when execution STARTS. An `until_executed` lock would still be held
  # at that moment and the reschedule would be dropped as a duplicate, ending
  # the chain after one batch.
  #
  # `lock_args_method` collapses the args so every link shares one key — two
  # chains running at once would hand the same events to both.
  sidekiq_options retry:            false,
    lock:             :until_executing,
    lock_args_method: ->(_args) { [] }

  # Long enough that the backfill never competes with a real request for the
  # connection pool, short enough that 2,563 events finish inside a minute.
  NEXT_IN = 2.seconds

  def self.start!
    perform_async
  end

  # Starts the walk over from the beginning. The rows already made are
  # untouched — `EventTransaction.sync` is idempotent, so a re-walk re-examines
  # them and creates nothing.
  def self.restart!
    ::SimpleFin::EventBackfill.reset!
    start!
  end

  def perform
    outcome = ::SimpleFin::EventBackfill.call
    ::Rails.logger.info("[SimpleFinEventBackfillWorker] #{outcome.to_log}")

    return if outcome.done?

    self.class.perform_in(NEXT_IN)
  end
end
