class TimerFireWorker
  include Sidekiq::Worker

  sidekiq_options retry: 3, queue: :default

  def perform(timer_id)
    timer = Timer.unscoped.find_by(id: timer_id)
    return unless timer && timer.archived_at.nil? && timer.end_at
    return if timer.fired_at.present?

    drift_ms = ((timer.end_at - Time.current) * 1000).to_i
    if drift_ms > 1000
      new_jid = self.class.perform_at(timer.end_at, timer.id)
      timer.update_columns(fire_jid: new_jid, fire_scheduled_for: timer.end_at)
      return
    end

    timer.fire_and_maybe_repeat!
  end
end
