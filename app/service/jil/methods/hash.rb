class Jil::Methods::Hash < Jil::Methods::Base
  def cast(value)
    case value
    when ::List then cast(value.jil_serialize)
    when ::Jil::Parser then cast(hash_wrap(evalargs(value.args)))
    when ::Array
      cast(value.each_with_object({}) { |item, obj|
        if item.is_a?(::Jil::Parser) && item.objname == :Keyval
          evalargs(item.args).tap { |k,v| obj[k] = v }
        elsif item.is_a?(::Array) && item.length == 2
          item.tap { |k,v| obj[k] = v }
        elsif item.is_a?(::Array)
          item
        end
      })
    else
      value.to_h.with_indifferent_access
    end
  end

  def enum_content(args)
    evalargs(args).first
  end

  def execute(line, method=nil)
    method ||= line.methodname
    case method
    when :parse then parse(enum_content(line.args))
    when :keyHash
      key, hash = *line.args
      { evalarg(key) => hash_wrap(evalargs(hash)) }
    when :keyval
      hash_wrap(evalargs(line.args))
    when :new
      if line.objname == :Hash
        hash_wrap(enum_content(line.args))
      else
        hash_wrap(evalargs(line.args))
      end
    when :dig
      token_val(line.objname).with_indifferent_access.send(method, *enum_content(line.args))
    when :get then token_val(line.objname).with_indifferent_access.dig(*enum_content(line.args))
    when :set!
      token = line.objname.to_sym
      @jil.ctx[:vars][token] ||= { class: :Hash, value: nil }
      @jil.ctx[:vars][token][:value] = token_val(line.objname).merge(hash_wrap(evalargs(line.args)))
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
    tz = ::NewTokenizer.new(raw.to_s.gsub(/\\(["'\\])/, '\1'), only: { "\"" => "\"" })
    processed = tz.untokenize(tz.tokenized_text.gsub(/(\w+): /, '"\1": ').gsub("nil", "null"))

    ::JSON.parse(processed).with_indifferent_access
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
