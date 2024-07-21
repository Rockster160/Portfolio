class Jil::Methods::Array < Jil::Methods::Base
  def cast(value)
    case value
    when ::Hash then value.to_a
    else ::Array.wrap(value)
    # when ::Array then cast(::JSON.stringify(value))
    # # when ::String then value
    # else
    #   value.to_s.gsub(/^\"|\"$/, "").gsub(/#\{\s*(.*?)\s*\}/) { |found|
    #     token = Regexp.last_match[1]
    #     var = @jil.ctx&.dig(:vars, token.to_sym) || {}
    #     cast(var[:value]).tap { |val|
    #       jil.ctx[:output] << "Unfound token (#{token})" if val.blank?
    #     }
    #   }
    end
  end

  # def execute(line)
    # case line.methodname
    # when :new then cast(evalarg(line.arg))
    # else
    #   if line.objname.match?(/^[A-Z]/)
    #     send(line.methodname, token_val(line.objname), *evalargs(line.args))
    #   else
    #     token_val(line.objname).send(line.methodname, *evalargs(line.args))
    #   end
    # end
  # end
end
# [Array]
# [ ] #new(content)
# [ ] #from_length(Numeric)
# [ ] .length::Numeric
# [ ] .merge
# [ ] .get(Numeric)::Any
# [ ] .set(Numeric "=" Any)
# [ ] .del(Numeric)
# [ ] .pop!::Any
# [ ] .push!(Any)
# [ ] .shift!::Any
# [ ] .unshift!(Any)
# [ ] .each(content(["Object"::Any "Index"::Numeric)])
# [ ] .map(content(["Object"::Any "Index"::Numeric)])
# [ ] .find(content(["Object"::Any "Index"::Numeric)])::Any
# [ ] .any?(content(["Object"::Any "Index"::Numeric)])::Boolean
# [ ] .none?(content(["Object"::Any "Index"::Numeric)])::Boolean
# [ ] .all?(content(["Object"::Any "Index"::Numeric)])::Boolean
# [ ] .sort_by(content(["Object"::Any "Index"::Numeric)])
# [ ] .sort_by!(content(["Object"::Any "Index"::Numeric)])
# [ ] .sort(["Ascending" "Descending" "Reverse" "Random"])
# [ ] .sort!(["Ascending" "Descending" "Reverse" "Random"])
# [ ] .sample::Any
# [ ] .min::Any
# [ ] .max::Any
# [ ] .sum::Any
# [ ] .join(String)::String
