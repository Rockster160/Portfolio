class Jil
  # data can be "something:nested:value" or json
  def self.trigger(user, scope, data={})
    trigger_now(user, scope, data)
  end

  def self.trigger_async(from_user, scope, data={})
    ::Jil::Schedule.add_schedule(from_user, ::Time.current, trigger, data)
  end

  def self.trigger_now(user, scope, data={})
    Jil::Executor.trigger(user, scope, data)
  end
end
