class JilScheduleWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    ::JilScheduledTrigger.not_scheduled.upcoming_soon.find_each do |schedule|
      ::Jil::Schedule.add_job(schedule)
    end

    jils = ::JilTask.enabled.where(next_trigger_at: ..Time.current)

    jils.find_each(&:execute)
  rescue StandardError => e
    SlackNotifier.err(e)
    raise
  end
end
