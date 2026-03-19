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

    task = @jil.user.tasks.active.enabled.functions.by_method_name(line.methodname).take
    raise ::Jil::ExecutionError, "Undefined Method #{line.methodname}" if task.blank?

    input_data = build_function_params(line.args)
    task.execute(input_data, broadcast_task: @jil.broadcast_task)&.result
  end

  private

  def build_function_params(args)
    content = args.flatten.select { |a| a.is_a?(::Jil::Parser) }
    named_args = content.select { |p|
      p.objname == :Keyword && p.methodname.to_s.match?(/\A[a-z_]/)
    }

    if named_args.present? && named_args.length == content.length
      named_args.each_with_object({}) { |parser, hash|
        hash[parser.methodname.to_s] = @jil.execute_block(parser)
      }
    else
      { params: evalargs(args) }
    end
  end
end
