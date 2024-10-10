class TriggerWorker
  include Sidekiq::Worker

  # jid = ::TriggerWorker.perform_at(date, schedule_id)
  def perform(schedule_id)
    schedule = ::JilScheduledTrigger.find_by(id: schedule_id)
    return if schedule.blank?
    return unless schedule.ready?

    # Trigger async which prevents errors messing up this job
    ::Jil.trigger(schedule.user_id, schedule.trigger, { schedule.trigger => schedule.data})

    schedule.destroy
  end
end
