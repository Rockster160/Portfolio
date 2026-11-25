class AppTimerPushWorker
  include Sidekiq::Worker

  sidekiq_options retry: 1, queue: :default

  def perform(timer_id, reason, user_id=nil, name=nil, rings_at=nil)
    timer = Timer.unscoped.find_by(id: timer_id)
    return AppPush::Timers.gone(timer_id, user_id, name, rings_at) if timer.nil?

    AppPush::Timers.sync(timer, reason)
  end
end
