class Jil::Methods::Array < Jil::Methods::Base
  def cast(value)
    case value
    when ::Hash then value.to_a
    else ::Array.wrap(value)
    end
  end

  # #new(content)
  # .splat(content(["Item"::Any]))
  # .dig(content(String|Numeric [String.new Numeric.new]))::Any
  # .each(enum_content)
  # .select(enum_content)::Array
  # .map(enum_content)
  # .find(enum_content)::Any
  # .any?(enum_content)::Boolean
  # .none?(enum_content)::Boolean
  # .all?(enum_content)::Boolean
  # .sort_by(enum_content)
  # .sort_by!(enum_content)

  def enum_content(args)
    evalargs(args).first
  end

  def init(line)
    enum_content(line.args)
  end

  def execute(line, method=nil)
    method ||= line.methodname
    case method
    when :splat then splat(line)
    when :from_length then ::Array.new(@jil.cast(evalarg(line.arg), :Numeric))
    when :combine then token_val(line.objname) + cast(evalarg(line.arg))
    when :dig then token_val(line.objname).send(method, *enum_content(line.args))
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
    when :each, :map, :any?, :none?, :all?
      @jil.enumerate_array(token_val(line.objname), method) { |ctx| evalarg(line.arg, ctx) }
    when :select, :sort_by
      @jil.enumerate_array(token_val(line.objname), method) { |ctx|
        evalarg(line.arg, ctx)
      }.map(&:first)
    when :sort
      token_val(line.objname).sort_by.with_index { |val, idx|
        case evalarg(line.arg).to_sym
        when :Ascending then val
        when :Descending then -val
        when :Reverse then -idx
        when :Random then rand
        end
      }
    when :sort_by!, :sort!
      token = line.objname.to_sym
      arr = token_val(token)
      @jil.ctx[:vars][token][:value] = execute(line, method.to_s[..-2].to_sym)
    when :find
      @jil.enumerate_array(token_val(line.objname), method) { |ctx|
        evalarg(line.arg, ctx)
      }.first
    else
      if line.objname.match?(/^[A-Z]/)
        send(method, token_val(line.objname), enum_content(line.args))
      elsif line.args.any?
        token_val(line.objname).send(method, enum_content(line.args))
      else
        token_val(line.objname).send(method)
      end
    end
  end

  def splat(line)
    array = token_val(line.objname)
    line.args.flatten.map.with_index { |arg, idx|
      next if idx >= array.length

      @jil.cast(array[idx], arg.cast).tap { |val|
        @jil.ctx[:vars][arg.varname] = {
          class: arg.cast,
          value: val,
        }
      }
    }.compact
  end
end
