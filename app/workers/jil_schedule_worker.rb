class JilScheduleWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform
    # Roll the AgendaSchedule materialization window forward so upcoming
    # occurrences (task/event/trigger) become real AgendaItem rows before
    # their start_at. Without this, recurring events stay phantom until
    # the past-window worker materializes them at start time, which is
    # too late for derived ScheduledTriggers (pre-event reminders) to
    # ever fire ahead of time.
    ::AgendaSchedule.find_each(&:materialize_upcoming!)

    ::ScheduledTrigger.not_scheduled.upcoming_soon.find_each do |schedule|
      ::Jil::Schedule.add_job(schedule)
    end

    ::Task.active.enabled.pending.distinct.pluck(:user_id).each do |user_id|
      next if User.advisory_lock_exists?("jil_runner_#{user_id}")

      ::JilRunnerWorker.perform_async(user_id)
      break # Only need to enqueue one runner per user, so break after the first
    end

    if ::Execution.exists?(started_at: 2.minutes.ago..)
      ::ExecutionCompactWorker.perform_async
    end
  end
end
