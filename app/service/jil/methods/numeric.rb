class Jil::Methods::Numeric < Jil::Methods::Base
  def cast(value)
    case value
    when FalseClass, NilClass then 0
    when TrueClass then 1
    else value.to_f.then { |n| n.to_i == n ? n.to_i : n}
    end
    # case value
    # when ::Hash then value.to_a
    # else ::Array.wrap(value)
    # # when ::Array then cast(::JSON.stringify(value))
    # # # when ::String then value
    # # else
    # #   value.to_s.gsub(/^\"|\"$/, "").gsub(/#\{\s*(.*?)\s*\}/) { |found|
    # #     token = Regexp.last_match[1]
    # #     var = @jil.ctx&.dig(:vars, token.to_sym) || {}
    # #     cast(var[:value]).tap { |val|
    # #       jil.ctx[:output] << "Unfound token (#{token})" if val.blank?
    # #     }
    # #   }
    # end
  end
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
# [ ]  .zero?
# [ ]  .even?
# [ ]  .odd?
# [ ]  .prime?
# [ ]  .whole?
# [ ]  .positive?
# [ ]  .negative?
