class JarvisScheduleWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    tasks = ::JarvisTask.enabled.where(next_trigger_at: ..Time.current)
    broadcast_after = tasks.any?
    tasks.find_each do |task|
      ::Jarvis::Execute.call(task) # These are run inline
    end
    ::BroadcastUpcomingWorker.perform_async if broadcast_after
  rescue StandardError => e
    SlackNotifier.err(e)
    raise
  end
end
