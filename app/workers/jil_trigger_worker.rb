class JilTriggerWorker
  include Sidekiq::Worker

  def perform(user_ids, trigger, trigger_data={})
    ::Jil::Executor.trigger(user_ids, trigger, trigger_data)
  end
end
