class Jil::Methods::Base
  attr_accessor :jil

  def cast(value)
    raise NotImplementedError, "[#{self.class}] does not implement `cast`"
  end

  def initialize(jil, ctx=nil)
    @jil = jil
    @ctx = ctx || jil.ctx
  end

  def evalarg(arg, passed_ctx=nil)
    if arg.is_a?(::Jil::Parser) || arg.is_a?(::Array)
      @jil.execute_block(arg, passed_ctx || @ctx || @jil.ctx)
    elsif arg.is_a?(::String) && !arg.match?(/^\".*?\"$/)
      token_val(arg)
    elsif arg.is_a?(::String) && arg.match?(/^\".*?\"$/)
      arg[1..-2].gsub(/\#\{\s*(.*?)\s*\}/) { |found|
        @jil.cast(token_val(Regexp.last_match[1]), :String)
      }
    else
      arg
    end
  end

  def evalargs(args)
    Array.wrap(args).map { |arg| arg.is_a?(::Array) ? evalargs(arg) : evalarg(arg) }
  end

  def token_val(token)
    raise ::Jil::ExecutionError, "Unfound token `#{token}`" unless @jil.ctx&.dig(:vars)&.key?(token.to_sym)

    @jil.ctx&.dig(:vars, token.to_sym, :value)
  end

  def execute(line) # TODO: Do not override this in lower classes, just have a different method to call
    case line.methodname
    when :new then cast(evalarg(line.arg))
    else
      fallback(line)
    end
  end

  def fallback(line)
    if line.objname.match?(/^[A-Z]/)
      send(line.methodname, *evalargs(line.args))
    elsif respond_to?(line.methodname)
      send(line.methodname, token_val(line.objname), *evalargs(line.args)).tap { |new_val|
        if line.methodname.ends_with?("!")
          token = line.objname.to_sym
          @jil.ctx[:vars][token][:value] = new_val
        end
      }
    else
      token_val(line.objname).send(line.methodname, *evalargs(line.args))
    end
  end

  def set_value(token, val, type: nil)
    token = token.to_sym
    @jil.ctx[:vars][token] ||= { class: type || :Any, value: val }
    @jil.ctx[:vars][token][:class] = type if type
    @jil.ctx[:vars][token][:value] = val
  end
end
