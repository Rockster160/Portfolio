class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(action)
    Jarvis.execute_trigger(action)
  end
end
