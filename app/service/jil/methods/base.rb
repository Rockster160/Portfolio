class Jil::Methods::Base
  attr_accessor :jil

  def cast(value)
    raise NotImplementedError, "[#{self.class}] does not implement `cast`"
  end

  def initialize(jil, ctx=nil)
    @jil = jil
    @ctx = ctx || jil.ctx
  end

  def evalarg(arg)
    if arg.is_a?(::Jil::Parser) || arg.is_a?(::Array)
      @jil.execute_block(arg)
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
    args.map { |arg| evalarg(arg) }
  end

  def token_val(token)
    @jil.ctx&.dig(:vars, token.to_sym, :value)
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
