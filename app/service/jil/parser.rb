class Jil::Parser
  attr_accessor :commented, :varname, :objname, :methodname, :args, :cast

  REGEX = /
    (?<commented>\#)?\s*
    (?:(?<varname>[_a-z][_0-9A-Za-z]*)\s*=\s*)?\s*
    (?<objname>[_a-zA-Z][_0-9A-Za-z]*)
    \.(?<methodname>[_0-9A-Za-z]+)
    \((?<args>[\s\S]*)\)
    ::(?<cast>[A-Z][_0-9A-Za-z]*)
  /x
  ESCAPED_REGEX = /
    (?<commented>\#)?\s*
    (?:(?<varname>[_a-z][_0-9A-Za-z]*)\s*=\s*)?\s*
    (?<objname>[_a-zA-Z][_0-9A-Za-z]*)
    \.(?<methodname>[_0-9A-Za-z]+)
    (?<args>\[[a-f0-9]{2}-[a-f0-9]{2}-[a-f0-9]{2}-[a-f0-9]{2}\])
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
          else
            piece
          end
        }
      }
      line = Jil::Parser.new(commented, varname, objname, methodname, args, cast)
    }#.tap { |vals|  }
  end

  def initialize(commented, varname, objname, methodname, args, cast)
    @commented = commented
    @varname = varname
    @objname = objname
    @methodname = methodname
    @args = args
    @cast = cast
  end
end
