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
  TOKEN_REGEX = /\|\|TOKEN\d+\|\|/
  ESCAPED_REGEX = /
    \s*(?<commented>\#)?\s*
    (?:(?<varname>[_a-z][_0-9A-Za-z]*)\s*=\s*)?\s*
    (?<objname>[_a-zA-Z][_0-9A-Za-z]*)
    \.(?<methodname>[_0-9A-Za-z]+[!?]?)
    (?<args>#{TOKEN_REGEX})
    ::(?<cast>[A-Z][_0-9A-Za-z]*)
  /xm

  def self.from_code(code)
    tk = NewTokenizer.new(code)
    escaped = tk.tokenized_text

    from_tokenized_code(escaped, tk).tap { |parsed|
      # binding.pry
    }
  end

  def self.from_tokenized_code(code, tk)
    code.scan(ESCAPED_REGEX)&.map.with_index { |(commented, varname, objname, methodname, arg_code, cast), idx|
      args = tk.untokenize(arg_code, 1, unwrap: true).split(/,?[ \n]+/).map { |escaped|
        untokenized = tk.untokenize(escaped)
        tk.untokenize(escaped, 1).then { |piece|
          if piece.starts_with?("{") && piece.ends_with?("}")
            from_tokenized_code(piece, tk)
          elsif untokenized.starts_with?("\"") && untokenized.ends_with?("\"")
            untokenized # keep quotes
          else
            begin
              ::JSON.parse(untokenized) rescue untokenized
            rescue JSON::ParserError => e
              untokenized
            end
          end
        }
      }
      ::Jil::Parser.new(commented, varname, objname, methodname, args, cast)
    }.tap { |vals|
      # binding.pry
    }
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
