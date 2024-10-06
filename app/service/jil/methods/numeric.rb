class Jil::Methods::Numeric < Jil::Methods::Base
  def cast(value)
    case value
    when FalseClass, NilClass then 0
    when TrueClass then 1
    when ::Array, ::Hash then value.length
    else value.to_f.then { |n| n.to_i == n ? n.to_i : n }
    end
  end

  def self.op(val1, operator, val2)
    raise ::Jil::ExecutionError, "invalid operator" unless operator.in?(["+", "-", "*", "/", "%", "^log"])

    return cast(val1) / cast(val2).to_f if operator == "/"
    cast(val1).send(operator, cast(val2))
  end

  def op(val1, operator, val2)
    raise ::Jil::ExecutionError, "invalid operator" unless operator.in?(["+", "-", "*", "/", "%", "^log"])

    return cast(val1) / cast(val2).to_f if operator == "/"
    cast(val1).send(operator, cast(val2))
  end

  def op!(val1, operator, val2)
    raise ::Jil::ExecutionError, "invalid operator" unless operator.in?(["+=", "-=", "*=", "/=", "%="])
    operator = operator[0] # Remove the `=`

    return cast(val1) / cast(val2).to_f if operator == "/"
    cast(val1).send(operator, cast(val2))
  end

  def evaluate(text)
    Dentaku(text)
  end

  # def rand(min, max, sig_figs)
  #   random_number = min + rand * (max - min)
  #   scale_factor = 10**sig_figs
  #   (random_number * scale_factor).round / scale_factor.to_f
  # end
end

# [Numeric]::number
# [ ]  #new(Any::Numeric)
# [ ]  #pi(TAB "π" TAB)
# [ ]  #e(TAB "e" TAB)
# [ ]  #inf()
# [ ]  #rand(Numeric:min Numeric:max Numeric?:figures)
# [ ]  .round(Numeric(0))
# [ ]  .floor
# [ ]  .ceil
# [ ]  .op(["+" "-" "*" "/" "^log"] Numeric)
# [ ]  .abs
# [ ]  .sqrt
# [ ]  .squared
# [ ]  .cubed
# [ ]  .log(Numeric)
# [ ]  .root(Numeric)
# [ ]  .exp(Numeric)
# [ ]  .zero?::Boolean
# [ ]  .even?::Boolean
# [ ]  .odd?::Boolean
# [ ]  .prime?::Boolean
# [ ]  .whole?::Boolean
# [ ]  .positive?::Boolean
# [ ]  .negative?::Boolean
