class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(user_id, trigger, trigger_data={})
    ::Jarvis.trigger_events(user_id, trigger, trigger_data)
  end
end
