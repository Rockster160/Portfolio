class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(trigger, trigger_data={}, scope={})
    Jarvis.execute_trigger(trigger, JSON.parse(trigger_data), scope: JSON.parse(scope))
  end
end
