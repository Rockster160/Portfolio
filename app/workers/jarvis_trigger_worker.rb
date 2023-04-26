class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(trigger, trigger_data={}, scope={})
    ::SlackNotifier.notify("Trigger worker:\n#{trigger}\n#{scope}\n trigger_data class:#{trigger_data.class}\n```#{trigger_data}```")
    Jarvis.execute_trigger(trigger, SafeJsonSerializer.load(trigger_data), scope: SafeJsonSerializer.load(scope))
  end
end
