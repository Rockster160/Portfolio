class Jil::Methods::Boolean < Jil::Methods::Base
  def cast(value)
    ::ActiveModel::Type::Boolean.new.cast(value)
  end

  def execute(line)
    case line.methodname
    when :new then cast(evalarg(line.arg))
    when :eq then soft_presence(line.args.first) == soft_presence(line.args.last)
    when :or then soft_presence(line.args.first) || soft_presence(line.args.last)
    when :and then soft_presence(line.args.first) && soft_presence(line.args.last)
    when :not then !soft_presence(line.args.first)
    when :compare
      left, sign, right = evalargs(line.args)
      if sign.in?(["==", "!="])
        @jil.cast(left).send(sign, @jil.cast(right))
      elsif sign.in?(["==", "!=", "<", "<=", ">", ">="])
        @jil.cast(left, :Numeric).send(sign, @jil.cast(right, :Numeric))
      end
    else
      send(line.methodname, line.args)
      # send(line.methodname, *evalargs(line.args))
    end
  end

  def soft_presence(arg)
    evalarg(arg).then { |val|
      case val
      when TrueClass, FalseClass then val
      else val.presence
      end
    }
  end
end
# [Boolean]::checkbox
#   #new(Any::Boolean)
#   #eq(Any "==" Any)
#   #or(Any "||" Any)
#   #and(Any "&&" Any)
#   #not("NOT" Any)
#   #compare(Any ["==" "!=" ">" "<" ">=" "<="] Any)
