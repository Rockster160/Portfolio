class Jil::Methods::Hash < Jil::Methods::Base
  def cast(value)
    case value
    when ::Jil::Parser then hash_wrap(evalargs(value.args))
    when ::Hash then value.to_h
    when ::Array
      value.each_with_object({}) { |item, obj|
        if item.is_a?(::Jil::Parser) && item.objname == :Keyval
          evalargs(item.args).tap { |k,v| obj[k] = v }
        elsif item.is_a?(::Array) && item.length == 2
          item.tap { |k,v| obj[k] = v }
        elsif item.is_a?(::Array)
          item
        end
      }
    else
      value.to_h
    end
  end

  def execute(line)
    case line.methodname
    when :new, :keyHash then hash_wrap(evalargs(line.args))
    when :get then token_val(line.objname).dig(*evalargs(line.args))
    when :set!
      token = line.objname.to_sym
      @jil.ctx[:vars][token] ||= { class: :Hash, value: nil }
      @jil.ctx[:vars][token][:value] = token_val(line.objname).merge(hash_wrap(evalargs(line.args)))
    when :del!
      token = line.objname.to_sym
      @jil.ctx[:vars][token] ||= { class: :Hash, value: nil }
      @jil.ctx[:vars][token][:value].delete(evalarg(line.arg))
      @jil.ctx[:vars][token][:value]
    when :each, :map, :any?, :none?, :all?
      @jil.enumerate_hash(token_val(line.objname), line.methodname) { |ctx| evalarg(line.arg, ctx) }
    when :filter
      @jil.enumerate_hash(token_val(line.objname), line.methodname) { |ctx|
        evalarg(line.arg, ctx)
      }.to_h { |(k,v),i| [k,v] }
    else
      if line.objname.match?(/^[A-Z]/)
        send(line.methodname, token_val(line.objname), *evalargs(line.args))
      else
        token_val(line.objname).send(line.methodname, *evalargs(line.args))
      end
    end
  end

  def hash_wrap(array)
    return array.to_h if array.first.is_a?(::Array)
    return [array].to_h if array.length == 2

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
