class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(trigger, trigger_data={}, scope={})
    Jarvis.execute_trigger(trigger, trigger_data, scope: scope)
  end
end
