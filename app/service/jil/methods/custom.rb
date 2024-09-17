class Jil::Methods::Custom < Jil::Methods::Base
  def cast(value)
    value
  end

  def execute(line)
    task = @jil.user.jil_tasks.functions.by_snake_name(line.methodname).take
    task&.execute(params: evalargs(line.args))&.result
  end
end
