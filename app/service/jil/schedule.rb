module Jil::Schedule
  module_function

  def add_schedules(users, execute_at, trigger, data, auth: nil, auth_id: nil)
    Array.wrap(users).filter_map { |user|
      add_schedule(user, execute_at, trigger, data, auth: auth, auth_id: auth_id)
    }
  end

  def add_schedule(user, execute_at, trigger, data, auth: nil, auth_id: nil)
    return if trigger.blank?

    schedule = ::ScheduledTrigger.create!(
      user_id:      ::User.id(user),
      trigger:      trigger,
      execute_at:   execute_at.presence || ::Time.current,
      data:         data,
      auth_type:    auth,
      auth_type_id: auth_id,
    )

    add_job(schedule) unless far_future?(schedule)
    broadcast(schedule, :created)
  end

  def broadcast(schedule, action)
    # Do not broadcast creation of immediate triggers since they're just function calls
    return schedule if immediate?(schedule) && action.to_sym == :created

    ::Jil.trigger(
      schedule.user, :schedule, { schedule_id: schedule.id, action: action },
      auth: schedule.auth_type || :trigger, auth_id: schedule.auth_type_id
    )
    schedule
  end

  def update(schedule) # Also run on create, but we need the schedule.id so it must be persisted.
    if schedule.jid.present?
      job = existing_job(schedule.jid)
      return if job && similar_time?(job.at, schedule.execute_at)

      cancel(schedule, job: job)
    end

    if far_future?(schedule)
      schedule.update!(jid: nil)
    else
      add_job(schedule)
    end
  end

  def cancel(schedule, job: nil)
    (job || existing_job(schedule.jid))&.delete
  end

  def add_job(schedule)
    user_id = schedule.user_id
    run_at = schedule.execute_at - 1.second

    # Only enqueue if no JilRunnerWorker is already queued/scheduled for this user
    unless runner_pending?(user_id, run_at)
      schedule.update!(
        jid: ::JilRunnerWorker.perform_at(run_at, user_id),
      )
    end
  end

  def runner_pending?(user_id, run_at)
    # Check if already running
    return true if ::User.advisory_lock_exists?("jil_runner_#{user_id}")

    # Check Sidekiq scheduled set for a JilRunnerWorker within range
    ::Sidekiq::ScheduledSet.new.any? { |j|
      j.klass == ::JilRunnerWorker.name &&
        j.args == [user_id] &&
        similar_time?(j.at, run_at)
    }
  end

  def existing_job(jid)
    ::Sidekiq::ScheduledSet.new.find { |j| j.jid == jid && j.klass == ::JilRunnerWorker.name }
  end

  def immediate?(schedule)
    schedule.created_at + 2.seconds > schedule.execute_at
  end

  def far_future?(schedule)
    schedule.execute_at > schedule.created_at + ::ScheduledTrigger::REDIS_OFFSET
  end

  def similar_time?(time1, time2, coverage=6.seconds)
    time1.then { |t| ((t - coverage)..(t + coverage)) }.cover?(time2)
  end
end
