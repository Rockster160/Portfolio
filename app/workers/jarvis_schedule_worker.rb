class JarvisScheduleWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    ::JilScheduledTrigger.not_scheduled.upcoming_soon.find_each do |schedule|
      ::Jil::Schedule.add_job(schedule)
    end

    tasks = ::JarvisTask.enabled.where(next_trigger_at: ..Time.current) # deprecated
    jils = ::JilTask.enabled.where(next_trigger_at: ..Time.current)

    tasks.find_each do |task|
      ::Jarvis::Execute.call(task) # These are run inline
    end
    jils.find_each do |task|
      task.execute
    end
  rescue StandardError => e
    SlackNotifier.err(e)
    raise
  end
end
