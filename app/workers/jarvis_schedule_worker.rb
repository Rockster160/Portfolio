class JarvisScheduleWorker
  include Sidekiq::Worker

  def perform
    ::JarvisTask.where(next_trigger_at: ..Time.current).find_each do |task|
      ::Jarvis::Execute.call(task)
    end
  end
end
