class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(action_data)
    Jarvis.execute_trigger(action_data)
  end
end
