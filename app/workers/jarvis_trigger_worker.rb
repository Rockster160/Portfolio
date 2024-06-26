class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(user_id, trigger, trigger_data={})
    ::Jarvis.trigger_events(user_id, trigger, trigger_data)
    # Jarvis.execute_trigger(trigger, trigger_data, scope: scope)
  end
end
