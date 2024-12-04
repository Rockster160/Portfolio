class Jil::Methods::String < Jil::Methods::Base
  def cast(value)
    case value
    when ::Hash then clean_json(value)
    when ::Array then clean_json(value)
    when ::Date, ::DateTime, ::Time, ActiveSupport::TimeWithZone then value.iso8601
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
    when :format then format(token_val(line.objname), cast(evalarg(line.arg)))
    when :replace then token_val(line.objname).gsub(*strreg_args(line.args))
    when :add then [token_val(line.objname), *strreg_args(line.args)].join("")
    when :match
      md = token_val(line.objname).match(to_regex(evalarg(line.arg)))
      case line.cast
      when :Array then md.to_a.presence
      when :Hash then md&.named_captures&.symbolize_keys.presence
      else md.to_a[1].presence || md.to_a.first.presence
      end
    when :split
      token_val(line.objname).split(to_regex(evalarg(line.arg)))
    else
      if line.objname.match?(/^[A-Z]/)
        send(line.methodname, string_or_regex(token_val(line.objname)), *evalargs(line.args))
      else
        token_val(line.objname).send(line.methodname, *evalargs(line.args))
      end
    end
  end

  def format(str, convert)
    case convert.to_sym
    when :lower then str.downcase
    when :upper then str.upcase
    when :squish then str.squish
    when :capital then str.capitalize
    when :capitalize_first then str.gsub(/^[a-z]/, &:upcase)
    when :pascal then str.gsub(/[^a-z0-9 ]/i, "").titleize.gsub(/\s+/, "")
    when :title then str.titleize
    when :snake then str.gsub(/[^a-z0-9 ]/i, "").underscore.gsub(" ", "_")
    when :camel then format(str, :snake).gsub(/_([a-z])/) { Regexp.last_match[-1].upcase }
    when :base64 then Base64.urlsafe_encode64(str)
    end
  end

  def strreg_args(*args)
    evalargs(*args).map { |str| string_or_regex(str) }
  end

  def to_regex(str)
    Regexp.new(str[/^\/(.*?)\/[img]*$/, 1] || str, Regexp::IGNORECASE | Regexp::MULTILINE)
  end

  def string_or_regex(str)
    # TODO: Support flags
    if str.starts_with?("/") && str.ends_with?("/")
      to_regex(str[1..-2])
    else
      str
    end
  end

  def clean_json(json)
    case json
    when ::Hash
      return "{}" if json.blank?

      json.map { |key, val|
        "#{key.to_s.match?(/^\w+$/) ? key : key.to_s.inspect}: #{clean_json(val)}"
      }.then { |arr| "{ #{arr.join(", ")} }" }
    when ::Array
      return "[]" if json.blank?

      "[#{json.map { |item| clean_json(item) }.join(", ")}]"
    else json.inspect
    end
  end
end
# [String]
# [√]  #new(Any)
# [√]  .match(String)
# [√]  .scan(String)::Array
# [ ]  .split(String?)::Array
# [ ]  .format(["lower" "upper" "squish" "capital" "capitalize_first" "pascal" "title" "snake" "camel" "base64"])
# [ ]  .replace(String "with" String)
# [ ]  .add("+" String)
# [ ]  .length()::Numeric
