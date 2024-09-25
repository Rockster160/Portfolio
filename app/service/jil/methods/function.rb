class Jil::Methods::Function < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
  end

  def execute(line)
    case line.methodname
    when :call then run(line)
    end
  end

  private

  def run(line)
    @ctx[:args] = {}
    arg_list, content = token_val(line.objname).values
    arg_list.split(/[,\s]+/).each_with_index { |arg_name, idx|
      break if idx > line.arg.length

      @ctx[:args][arg_name.to_sym] = evalarg(line.arg[idx])
    }
    lines = ::Jil::Parser.from_code(content)
    @jil.execute_block(lines, @ctx).tap {
      @ctx.delete(:args)
      @ctx[:break] = false
      @ctx[:next] = false
    }
  end

end
