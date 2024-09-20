class Jil::Methods::Boolean < Jil::Methods::Base
  def cast(value)
    ::ActiveModel::Type::Boolean.new.cast(value)
  end

  def execute(line)
    case line.methodname
    when :new then cast(evalarg(line.arg))
    when :eq then evalarg(line.args.first).presence == evalarg(line.args.last).presence
    when :or then evalarg(line.args.first).presence || evalarg(line.args.last).presence
    when :and then evalarg(line.args.first).presence && evalarg(line.args.last).presence
    when :not then !evalarg(line.args.first).presence
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
end
# [Boolean]::checkbox
#   #new(Any::Boolean)
#   #eq(Any "==" Any)
#   #or(Any "||" Any)
#   #and(Any "&&" Any)
#   #not("NOT" Any)
#   #compare(Any ["==" "!=" ">" "<" ">=" "<="] Any)
