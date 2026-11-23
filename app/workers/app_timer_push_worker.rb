class AppTimerPushWorker
  include Sidekiq::Worker

  sidekiq_options retry: 1, queue: :default

  def perform(timer_id, reason)
    timer = Timer.unscoped.find_by(id: timer_id)
    return AppPush::Timers.gone(timer_id) if timer.nil?

    AppPush::Timers.sync(timer, reason)
  end
end
