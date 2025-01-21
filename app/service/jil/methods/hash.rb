class Jil::Methods::Hash < Jil::Methods::Base
  def self.parse(raw)
    tz = ::Tokenizer.new(raw.to_s.gsub(/\\(["'\\])/, '\1'), only: { "\"" => "\"", "'" => "'" })
    # TODO: Deal with hash rocket syntax
    # Also make sure to handle symbols: `"[:a]"` → `"[\"a\"]"`
    processed = tz.untokenize(tz.tokenized_text.gsub(/(\w+): /, '"\1": ').gsub("nil", "null")) do |str|
      str.gsub(/^'(.*?)'$/, '"\1"')
        .gsub(/(\\*)\\\n/, "\\n") # TODO: negative lookbehind to make sure it's not escaped
    end

    ::JSON.parse(processed).then { |j| j.is_a?(Hash) ? j.with_indifferent_access : j }
  end

  def cast(value)
    case value
    when ::List then cast(value.serialize)
    when ::Jil::Parser then cast(hash_wrap(evalargs(value.args)))
    when ::Array
      cast(value.each_with_object({}) { |item, obj|
        if item.is_a?(::Jil::Parser) && item.objname == :Keyval
          evalargs(item.args).tap { |k,v| obj[k] = v }
        elsif item.is_a?(::Array) && item.length == 2
          item.tap { |k,v| obj[k] = v }
        elsif item.is_a?(::Array)
          item
        elsif item.is_a?(::Hash)
          obj.merge!(item)
        end
      })
    when ::String
      begin
        value.present? ? parse(value) : {}.with_indifferent_access
      rescue JSON::ParserError
        {}.with_indifferent_access
      end
    else
      value.to_h.with_indifferent_access
    end
  end

  def enum_content(args)
    evalargs(args).first
  end

  def init(line)
    if line.objname == :Hash
      hash_wrap(enum_content(line.args))
    else
      hash_wrap(evalargs(line.args))
    end
  end

  def execute(line, method=nil)
    method ||= line.methodname
    case method
    when :splat then splat(line)
    when :parse then parse(enum_content(line.args))
    when :keyHash
      key, hash = *line.args
      { evalarg(key) => hash_wrap(evalargs(hash)) }
    when :keyval
      hash_wrap(evalargs(line.args))
    when :dig
      token_val(line.objname).with_indifferent_access.send(method, *enum_content(line.args))
    when :get then token_val(line.objname).with_indifferent_access.dig(*enum_content(line.args))
    when :set!
      val = token_val(line.objname).merge(hash_wrap(evalargs(line.args)))
      set_value(line.objname, val, type: :Hash)
    when :setData!
      val = token_val(line.objname).merge(hash_wrap(*evalargs(line.args)))
      set_value(line.objname, val, type: :Hash)
    when :del!
      token = line.objname.to_sym
      @jil.ctx[:vars][token] ||= { class: :Hash, value: {} }
      @jil.ctx[:vars][token][:value]&.delete(evalarg(line.arg))
      @jil.ctx[:vars][token][:value]
    when :each, :map, :any?, :none?, :all?
      @jil.enumerate_hash(token_val(line.objname), method) { |ctx| evalarg(line.arg, ctx) }
    when :filter
      @jil.enumerate_hash(token_val(line.objname), method) { |ctx|
        evalarg(line.arg, ctx)
      }.to_h { |(k,v),i| [k,v] }.with_indifferent_access
    else
      if line.objname.match?(/^[A-Z]/)
        send(method, token_val(line.objname), enum_content(line.args))
      elsif line.args.any?
        token_val(line.objname).with_indifferent_access.send(method, enum_content(line.args))
      else
        token_val(line.objname).with_indifferent_access.send(method)
      end
    end
  end

  def parse(raw)
    self.class.parse(raw)
    # TODO: Rescue and bubble better error
  end

  def hash_wrap(array)
    return array.to_h if array.first.is_a?(::Array) && array.first.length == 2
    return [array].to_h if array.length == 2 && array.none? { |i| i.is_a?(::Hash) }

    first, *rest = *array
    if first.is_a?(::String) || first.is_a?(::Symbol)
      { first => rest.inject({}) { |acc, hash| acc.merge(hash) } }
    else
      array.inject({}) { |acc, hash| acc.merge(hash) }
    end
  end

  def splat(line)
    hash = token_val(line.objname)
    line.args.flatten.each_with_object({}) { |(arg, idx), obj|
      @jil.cast(hash[@jil.cast(arg.arg, :String)], arg.cast).tap { |val|
        obj[arg.varname] = set_value(arg.varname, val, type: arg.cast)
      }
    }
  end
end
# [Hash]
#   #new(content(Keyval [Keyval.new]))
#   #keyval(String Any)::Keyval
#   .length::Numeric
#   .dig(content(String [String.new]))::Any
#   .merge(Hash)
#   .keys::Array
#   .get(String)::Any
#   .set!(String "=" Any)
#   .del!(String)
#   .each(content(["Key"::String "Value"::Any "Index"::Numeric)])
#   .map(content(["Key"::String "Value"::Any "Index"::Numeric)])::Array
#   .any?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
#   .none?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
#   .all?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
