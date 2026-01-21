class Jil::Methods::Custom < Jil::Methods::Base
  def cast(value)
    value
  end

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case method_sym
    when :distance
      if @jil.user.me?
        from, to, at = evalargs(line.args)
        return @jil.user.address_book.traveltime_seconds(to, from.presence, at: at.presence)
      end
    end

    task = @jil.user.tasks.enabled.functions.by_method_name(line.methodname).take
    raise ::Jil::ExecutionError, "Undefined Method #{line.methodname}" if task.blank?

    task.execute({ params: evalargs(line.args) }, broadcast_task: @jil.broadcast_task)&.result
  end
end
