class Jil::Methods::Boolean < Jil::Methods::Base
  def cast(value)
    ::ActiveModel::Type::Boolean.new.cast(value)
  end

  def execute(line)
    case line.methodname
    when :new then cast(evalarg(line.arg))
    when :eq then evalarg(line.args.first) == evalarg(line.args.last)
    when :or then evalarg(line.args.first) || evalarg(line.args.last)
    when :and then evalarg(line.args.first) && evalarg(line.args.last)
    when :not then !evalarg(line.args.first)
    when :compare
      left, sign, right = evalargs(line.args)
      return unless sign.in?(["==", "!=", "<", "<=", ">", ">="])

      @jil.cast(left, :Numeric).send(sign, @jil.cast(right, :Numeric))
    else send(line.methodname, line.args)
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
