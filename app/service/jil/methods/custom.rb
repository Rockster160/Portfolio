class Jil::Methods::Custom < Jil::Methods::Base
  def cast(value)
    value
  end

  def execute(line)
    task = @jil.user.jil_tasks.functions.by_method_name(line.methodname).take
    raise ::Jil::ExecutionError, "Undefined Method #{line.methodname}" if task.blank?

    task.execute(params: evalargs(line.args))&.result
  end
end
