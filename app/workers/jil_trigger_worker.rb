class JilTriggerWorker
  include Sidekiq::Worker

  def perform(user_ids, trigger, trigger_data={})
    ::Jil.trigger_now(user_ids, trigger, trigger_data)
  end
end
