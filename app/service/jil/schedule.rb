module Jil::Schedule
  module_function

  def add_schedules(users, execute_at, trigger, data)
    Array.wrap(users).filter_map { |user|
      add_schedule(user, execute_at, trigger, data)
    }
  end

  def add_schedule(user, execute_at, trigger, data)
    schedule = ::ScheduledTrigger.create(
      user_id: ::User.id(user),
      trigger: trigger,
      execute_at: execute_at.presence || ::Time.current,
      data: data,
    )
    return unless schedule.persisted?

    add_job(schedule) unless far_future?(schedule)
    broadcast(schedule, :created)
  end

  def broadcast(schedule, action)
    ::Jil.trigger(schedule.user, :schedule, schedule.serialize.merge(action: action))
    schedule
  end

  def update(schedule) # Also run on create, but we need the schedule.id so it must be persisted.
    if schedule.jid.present?
      job = existing_job(schedule.jid)
      return if job && similar_time?(job.at, schedule.execute_at)

      cancel(schedule, job: job)
    end

    if far_future?(schedule)
      schedule.update(jid: nil)
    else
      add_job(schedule)
    end
  end

  def cancel(schedule, job: nil)
    (job || existing_job(schedule.jid))&.delete
  end

  def add_job(schedule)
    schedule.update(
      # Offset 1 second to make up for async slowness
      jid: ::TriggerWorker.perform_at(schedule.execute_at-1.second, schedule.id),
    )
  end

  def existing_job(jid)
    ::Sidekiq::ScheduledSet.new.find { |j| j.jid == jid && j.klass == ::TriggerWorker.name }
  end

  def far_future?(schedule)
    schedule.execute_at > ::ScheduledTrigger::REDIS_OFFSET.from_now
  end

  def similar_time?(time1, time2, coverage=6.seconds)
    time1.then { |t| ((t-coverage)..(t+coverage)) }.cover?(time2)
  end
end
