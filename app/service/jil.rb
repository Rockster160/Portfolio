class Jil
  # data can be "something.nested.value" or json
  def self.trigger(user_id, scope, data={})
    return trigger_now(user_id, scope, data) if Rails.env.development?
    Jil::Executor.async_trigger(user_id, scope, data)
  end

  def self.trigger_async(user_id, scope, data={})
    trigger(user_id, scope, data)
  end

  def self.trigger_now(user_id, scope, data={})
    Jil::Executor.trigger(user_id, scope, data)
  end
end
