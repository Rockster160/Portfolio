class Jil::Methods::Array < Jil::Methods::Base
  def cast(value)
    load("/Users/rocco/.pryrc"); source_puts "#{value.class}:\n  #{value.inspect}"
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

  def execute(line)
    load("/Users/rocco/.pryrc"); source_puts line.inspect
    case line.methodname
    when :new then evalargs(line.args)
    when :from_length then ::Array.new(@jil.cast(evalarg(line.arg), :Numeric))
    when :combine then token_val(line.objname) + cast(evalarg(line.arg))
    when :get then token_val(line.objname)[@jil.cast(evalarg(line.arg), :Numeric)]
    when :pop! then token_val(line.objname).pop
    when :shift! then token_val(line.objname).shift
    when :push then token_val(line.objname).dup.push(*cast(evalarg(line.arg)))
    when :push! then token_val(line.objname).push(*cast(evalarg(line.arg)))
    when :unshift then token_val(line.objname).dup.unshift(*cast(evalarg(line.arg)))
    when :unshift! then token_val(line.objname).unshift(*cast(evalarg(line.arg)))
    when :set
      idx, val = *evalargs(line.args)
      arr = token_val(line.objname).dup
      arr[@jil.cast(idx, :Numeric)] = val
      arr
    when :set!
      idx, val = *evalargs(line.args)
      arr = token_val(line.objname)
      arr[@jil.cast(idx, :Numeric)] = val
      arr
    when :del! then token_val(line.objname).delete_at(@jil.cast(evalarg(line.arg), :Numeric))
      # idx, val = *evalargs(line.args)
      # arr =
      # arr[] = val
      # arr
    # when :new, :keyHash then hash_wrap(evalargs(line.args))
    # when :get then token_val(line.objname).dig(*evalargs(line.args))
    # when :set!
      # token = line.objname.to_sym
    #   @jil.ctx[:vars][token] ||= { class: :Hash, value: nil }
    #   @jil.ctx[:vars][token][:value] = token_val(line.objname).merge(hash_wrap(evalargs(line.args)))
    # when :del!
    #   token = line.objname.to_sym
    #   @jil.ctx[:vars][token] ||= { class: :Hash, value: nil }
    #   @jil.ctx[:vars][token][:value].delete(evalarg(line.arg))
    #   @jil.ctx[:vars][token][:value]
    # when :each, :map, :any?, :none?, :all?
    #   @jil.enumerate_hash(token_val(line.objname), line.methodname) { |ctx| evalarg(line.arg, ctx) }
    # when :filter
    #   @jil.enumerate_hash(token_val(line.objname), line.methodname) { |ctx|
    #     evalarg(line.arg, ctx)
    #   }.to_h { |(k,v),i| [k,v] }
    else
      if line.objname.match?(/^[A-Z]/)
        send(line.methodname, token_val(line.objname), *evalargs(line.args))
      else
        token_val(line.objname).send(line.methodname, *evalargs(line.args))
      end
    end
  end
end
