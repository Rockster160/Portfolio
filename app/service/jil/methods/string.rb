class Jil::Methods::String < Jil::Methods::Base
  def cast(value)
    case value
    when ::Hash then cast(::JSON.stringify(value))
    when ::Array then cast(::JSON.stringify(value))
    # when ::String then value
    else
      value.to_s.gsub(/^\"|\"$/, "").gsub(/#\{\s*(.*?)\s*\}/) { |found|
        token = Regexp.last_match[1]
        var = @jil.ctx&.dig(:vars, token.to_sym) || {}
        cast(var[:value]).tap { |val|
          jil.ctx[:output] << "Unfound token (#{token})" if val.blank?
        }
      }
    end
  end

  def execute(line)
    case line.methodname
    when :new then cast(line.arg)
    else
      if line.objname.match?(/^[A-Z]/)
        send(line.methodname, token_val(line.objname), *evalargs(line.args))
      else
        token_val(line.objname).send(line.methodname, *evalargs(line.args))
      end
    end
  end
end
# [String]
# [√]  #new(Any)
# [√]  .match(String)
# [√]  .scan(String)::Array
# [ ]  .split(String?)::Array
# [ ]  .format(["lower" "upper" "squish" "capital" "pascal" "title" "snake" "camel" "base64"])
# [ ]  .replace(String)
# [ ]  .add("+" String)
# [ ]  .length()::Numeric
