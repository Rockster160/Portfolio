class Jil::Parser
  attr_accessor :commented, :varname, :objname, :methodname, :args, :cast

  # REGEX = /
  #   \s*(?<commented>\#)?\s*
  #   (?:(?<varname>[_a-z][_0-9A-Za-z]*)\s*=\s*)?\s*
  #   (?<objname>[_a-zA-Z][_0-9A-Za-z]*)
  #   \.(?<methodname>[_0-9A-Za-z]+)
  #   \((?<args>[\s\S]*)\) -- Only difference from ESCAPED_REGEX
  #   ::(?<cast>[A-Z][_0-9A-Za-z]*)
  # /x
  ESCAPED_REGEX = /
    \s*(?<commented>\#)?\s*
    (?:(?<varname>[_a-z][_0-9A-Za-z]*)\s*=\s*)?\s*
    (?<objname>[_a-zA-Z][_0-9A-Za-z]*)
    \.(?<methodname>[_0-9A-Za-z]+)
    (?<args>\[[a-z0-9]{2}-[a-z0-9]{2}-[a-z0-9]{2}-[a-z0-9]{2}\])
    ::(?<cast>[A-Z][_0-9A-Za-z]*)
  /xm

  def self.from_code(code)
    tk = Tokenizer.new(code)
    escaped = tk.stepper(code)

    from_tokenized_code(escaped, tk).tap { |parsed|
      # binding.pry
    }
  end

  def self.from_tokenized_code(code, tk)
    code.scan(ESCAPED_REGEX)&.map.with_index { |(commented, varname, objname, methodname, arg_code, cast), idx|
      args = tk.untokenize(arg_code, 1)[1..-2].split(/,?[ \n]+/).map { |escaped|
        tk.untokenize(escaped, 1).then { |piece|
          if piece.starts_with?("{") && piece.ends_with?("}")
            from_tokenized_code(piece, tk)
          elsif piece.starts_with?("\"") && piece.ends_with?("\"")
            piece[1..-2]
          else
            piece
          end
        }
      }
      ::Jil::Parser.new(commented, varname, objname, methodname, args, cast)
    }#.tap { |vals|  }
  end

  def initialize(commented, varname, objname, methodname, args, cast)
    @commented = commented.present?
    @varname = varname.to_sym
    @objname = objname.to_sym
    @methodname = methodname.to_sym
    @args = Array.wrap(args)
    @cast = cast.to_sym
  end

  def commented?
    commented
  end

  def arg
    args.first
  end

  def cast_arg
    cast_args.first
  end

  def cast_args
    args.map { |arg|  }
  end
end
