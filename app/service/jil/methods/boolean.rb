class Jil::Methods::Boolean < Jil::Methods::Base
  def cast(value)
    ::ActiveModel::Type::Boolean.new.cast(value)
  end

  def execute(line)
    case line.methodname
    when :new then line.arg
    when :eq then evalarg(line.arg) == evalarg(line.args.last)
    when :or then evalarg(line.arg) || evalarg(line.args.last)
    when :and then evalarg(line.arg) && evalarg(line.args.last)
    when :not then !evalarg(line.arg)
    when :compare
      left, sign, right = evalargs(line.args)
      return unless sign.in?(["==", "!=", "<", "<=", ">", ">="])

      left.send(sign, right)
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
