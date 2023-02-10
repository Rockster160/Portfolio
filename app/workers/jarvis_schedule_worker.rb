class JarvisScheduleWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    tasks = ::JarvisTask.where(next_trigger_at: ..Time.current)
    tasks.find_each do |task|
      ::Jarvis::Execute.call(task)
    end
    ::BroadcastUpcomingWorker.perform_async if tasks.any?
  end
end
