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
      @jil.execute_block(arg, passed_ctx || @jil.ctx)
    elsif arg.is_a?(::String) && !arg.match?(/^\".*?\"$/)
      # This is hacky... Shouldn't we know if it's a string vs variable?
      @jil.ctx&.dig(:vars).key?(arg.to_sym) ? token_val(arg) : arg
    # elsif arg.is_a?(::Hash) && arg.keys == [:cast, :value]
    #   @jil.cast(arg[:value], arg[:cast], @ctx)
    else
      arg
    end
  end

  def evalargs(args)
    Array.wrap(args).flatten.map { |arg| evalarg(arg) }
  end

  def token_val(token)
    raise ::Jil::ExecutionError, "Unfound token `#{token}`" unless @jil.ctx&.dig(:vars)&.key?(token.to_sym)

    @jil.ctx&.dig(:vars, token.to_sym, :value)
  end

  def execute(line)
    case line.methodname
    when :new then cast(evalarg(line.arg))
    else
      if line.objname.match?(/^[A-Z]/)
        send(line.methodname, token_val(line.objname), *evalargs(line.args))
      elsif respond_to?(line.methodname)
        send(line.methodname, token_val(line.objname), *evalargs(line.args))
      else
        token_val(line.objname).send(line.methodname, *evalargs(line.args))
      end
    end
  end
end
