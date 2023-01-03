class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(trigger_data)
    Jarvis.execute_trigger(JSON.parse(trigger_data))
  end
end
