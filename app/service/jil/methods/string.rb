class Jil::Methods::String < Jil::Methods::Base
  def cast(value)
    case value
    when ::Hash then cast(::JSON.stringify(value))
    when ::Array then cast(::JSON.stringify(value))
    # when ::String then value
    else
      # @ctx[:vars][line.varname.to_sym]
      value.to_s.gsub(/#\{\s*(.*?)\s*\}/) do |found|
        token = Regexp.last_match[1]
        # vars = jil&.ctx&.dig(:vars) || {}
        # token_val = vars[token]
        # token_val ||= vars.find { |k, v|
        #   token.downcase.gsub(/\:var$/, "") == k.downcase.gsub(/\:var$/, "")
        # }&.dig(1)
        # if token_val.nil?
        #   jil.ctx[:msg] << "Unfound token (#{token})"
        # end
        # str(token_val, jil)
      end
    end
  end
end
#  [ ]
