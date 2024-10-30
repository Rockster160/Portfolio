class TriggerWorker
  include Sidekiq::Worker

  # jid = ::TriggerWorker.perform_at(date, schedule_id)
  def perform(schedule_id)
    schedule = ::ScheduledTrigger.find_by(id: schedule_id)
    return if schedule.blank?
    return unless schedule.ready? # TODO: Probably need to reschedule the job? Make sure to verify the jid

    # Trigger async which prevents errors messing up this job
    ::Jil.trigger(schedule.user_id, schedule.trigger, schedule.data)

    schedule.destroy
    # trigger now to prevent snowball / recursion
    ::Jil.trigger_now(schedule.user_id, :schedule, schedule.serialize.merge(action: :complete).except(:id))
  end
end
