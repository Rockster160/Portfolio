class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(trigger, trigger_data={}, scope={})
    Jarvis.execute_trigger(trigger, SafeJsonSerializer.load(trigger_data), scope: SafeJsonSerializer.load(scope))
  end
end
