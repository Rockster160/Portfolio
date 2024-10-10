class JarvisScheduleWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    ::JilScheduledTrigger.not_scheduled.upcoming_soon.find_each do |schedule|
      ::Jil::Schedule.add_job(schedule)
    end

    tasks = ::JarvisTask.enabled.where(next_trigger_at: ..Time.current) # deprecated
    crons = ::CronTask.enabled.where(next_trigger_at: ..Time.current) # deprecated
    jils = ::JilTask.enabled.where(next_trigger_at: ..Time.current)
    broadcast_after = tasks.any? || crons.any?

    crons.find_each do |task|
      ::Jarvis.command(task.user, task.command) # These are run inline
      task.update(last_trigger_at: Time.current) # Reschedules next_trigger_at
      # JarvisWorker.perform_async(task.user_id, task.command)
    end
    tasks.find_each do |task|
      ::Jarvis::Execute.call(task) # These are run inline
    end
    jils.find_each do |task|
      task.execute
    end

    ::BroadcastUpcomingWorker.perform_async if broadcast_after
  rescue StandardError => e
    SlackNotifier.err(e)
    raise
  end
end
