class Jil
  # data can be "something:nested:value" or json
  def self.trigger(user, scope, data={}, auth: :trigger, auth_id: nil)
    Jil::Executor.trigger(user, scope, data, auth: auth, auth_id: auth_id)
  end
end
