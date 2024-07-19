class Jil::Methods::String < Jil::Methods::Base
  def cast(value)
    case value
    when ::Hash then cast(::JSON.stringify(value))
    when ::Array then cast(::JSON.stringify(value))
    # when ::String then value
    else
      value.to_s.gsub(/#\{\s*(.*?)\s*\}/) do |found|
        token = Regexp.last_match[1]
        var = @jil.ctx&.dig(:vars, token.to_sym) || {}
        cast(var[:value]).tap { |val|
          jil.ctx[:output] << "Unfound token (#{token})" if val.blank?
        }
      end
    end
  end
end
#  [ ]
