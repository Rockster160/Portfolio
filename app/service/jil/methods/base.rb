class Jil::Methods::Base
  attr_accessor :jil

  def cast(value)
    raise NotImplementedError, "[#{self.class}] does not implement `cast`"
  end

  def execute(line)
    raise NotImplementedError, "[#{self.class}] does not implement `execute`"
  end

  def initialize(jil, ctx=nil)
    @jil = jil
    @ctx = ctx || jil.ctx
  end

  def evalarg(arg)
    if arg.is_a?(::Jil::Parser) || arg.is_a?(::Array)
      @jil.execute_block(arg)
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
end
