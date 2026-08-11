class SimpleFinBalanceChaseWorker
  include Sidekiq::Worker

  # Uniqueness is Sidekiq's job, not ours. Two options make that work:
  #
  # `lock_args_method` collapses the args to [], so attempt 1, 2 and 3 all
  # share ONE lock key — otherwise each link in the chain would look like a
  # different job and the whole point would be lost.
  #
  # `:until_executing` (not `:until_executed`) because this worker re-enqueues
  # itself from inside `perform`. An until_executed lock is still held at that
  # moment, so the reschedule would be silently dropped as a duplicate and the
  # chain would die after one attempt. until_executing releases the lock when
  # execution starts, which also means a crash cannot wedge it — there is no
  # flag left set behind a job that never finished.
  #
  # `retry: false` because rescheduling IS the retry and it carries the attempt
  # count; Sidekiq's own retry would rerun the same attempt on its own backoff
  # and spend requests outside the cap.
  sidekiq_options retry:            false,
    lock:             :until_executing,
    lock_args_method: ->(_args) { [] }

  # Worst case four extra requests on top of the six scheduled runs a day, so
  # the pair stays well inside the Bridge's ~24/day. Four hours is also about
  # as long as chasing is worth — past that the scheduled sync catches it.
  MAX_ATTEMPTS = 4
  RETRY_IN = 1.hour

  # Always enqueues. If a chase is already queued or scheduled, the uniqueness
  # lock drops this one — which is the entire dedupe story. A busy afternoon
  # can raise a dozen boundary-crossing alerts and only the first survives.
  def self.start!
    perform_async(1)
  end

  def perform(attempt=1)
    return unless ::SimpleFin::Client.configured?

    before = ::SimpleFin::DashboardCache.thousands
    ::SimpleFin::Refresh.call
    after = ::SimpleFin::DashboardCache.thousands

    if before != after
      log("balance moved #{before}k -> #{after}k on attempt #{attempt}")
    elsif attempt >= MAX_ATTEMPTS
      # Not a failure. The charge may simply not have posted yet, or the alert
      # was a deposit and the balance went the other way.
      log("still #{after}k after #{attempt} attempts; leaving it to the schedule")
    else
      self.class.perform_in(RETRY_IN, attempt + 1)
    end
  end

  private

  def log(reason)
    ::Rails.logger.info("[SimpleFinBalanceChaseWorker] #{reason}")
  end
end
