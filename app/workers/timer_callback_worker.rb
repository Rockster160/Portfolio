class TimerCallbackWorker
  include Sidekiq::Worker
  sidekiq_options queue: :default, retry: 1

  # Fires ONE mid-countdown callback for a timer. Scheduled at
  # `end_at - remaining_ms` by Timer#reschedule_countdown_callbacks!
  # whenever the timer starts/resumes/edits.
  #
  # Sound callbacks are skipped server-side (the page ticker handles
  # those locally). Push / Jil / chain run here so the trigger fires
  # even when no client is open.
  def perform(timer_id, callback_id)
    timer = Timer.find_by(id: timer_id)
    return unless timer && timer.countdown? && timer.running?

    timer.fire_callback_by_id!(callback_id)
  end
end
