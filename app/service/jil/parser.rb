class Jil::Parser
  attr_accessor :commented, :show, :varname, :objname, :methodname, :args, :cast, :code

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
    (?<whitespace>\s*)
    (?<commented>\#\s*)?
    (?<show>\*)?
    (?:(?<varname>[_a-z][_0-9A-Za-z]*)\s*=\s*)?\s*
    (?<objname>[_a-zA-Z][_0-9A-Za-z]*)
    \.(?<methodname>[_0-9A-Za-z]+[!?]?)
    (?<args>#{TOKEN_REGEX})
    ::(?<cast>[A-Z][_0-9A-Za-z]*)
  /xm
  COLORS = {
    syntax: 37, # whiteish
    err: 31, # red
    commented: "3;90", # grey
    objname: 31, # red (const or variable)
    castto: 90,

    varname: 94, # cyan
    variable: 94, # cyan

    methodname: 37, # whiteish
    const: 96, # yellow
    cast: "3;36", # grey
    constant: 35, # purple
    string: 32, # green
    numeric: 33, # light blue
  }.freeze

  def self.from_code(code)
    tk = NewTokenizer.new(code)
    escaped = tk.tokenized_text

    from_tokenized_code(escaped, tk).tap { |parsed|
      # binding.pry
    }
  end

  def self.from_tokenized_code(code, tk)
    code.scan(ESCAPED_REGEX)&.map.with_index { |(whitespace, commented, show, varname, objname, methodname, arg_code, cast), idx|
      raw = "#{'# ' if commented}#{'*' if show}#{varname} = #{objname}.#{methodname}#{arg_code}::#{cast}"
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
      ::Jil::Parser.new(commented, show, varname, objname, methodname, args, cast, tk.untokenize(raw))
    }.tap { |vals|
      # binding.pry
    }
  end

  def self.syntax_highlighting(code, tk=nil)
    col = ->(color, text) { "\e[#{COLORS[color]}m#{text}\e[0m\e[#{COLORS[:syntax]}m" }
    escaped = code if tk.present?
    tk ||= NewTokenizer.new(code)
    escaped ||= tk.tokenized_text

    escaped.scan(ESCAPED_REGEX)&.map.with_index { |(whitespace, commented, show, varname, objname, methodname, arg_code, cast), idx|
      args = tk.untokenize(arg_code, 1, unwrap: true).split(/,?[ \n]+/).map { |nested|
        untokenized = tk.untokenize(nested)
        tk.untokenize(nested, 1).then { |piece|
          if piece.starts_with?("{") && piece.ends_with?("}")
            next piece if piece == "{}"
            [
              "{#{whitespace.gsub(/^\r?\n/, "")}  ",
              syntax_highlighting(piece, tk),
              "\n#{whitespace.gsub(/^\r?\n/, "")}#{commented}}",
            ].join
          elsif untokenized.starts_with?("\"") && untokenized.ends_with?("\"")
            # untokenized to keep quotes
            col[:string, untokenized].gsub(/(#\{\s*)(\w+)(\s*\})/) do |found|
              _, start, word, finish = Regexp.last_match.to_a
              [
                col[:syntax, start],
                col[:variable, word],
                col[:syntax, finish],
                "\e[#{COLORS[:string]}m",
              ].join
            end
          else
            case untokenized
            when /^\d+$/
              col[:numeric, untokenized]
            when /^(nil|null|true|false)$/
              col[:constant, untokenized]
            when /^\w+$/
              col[:variable, untokenized]
            else
              col[:err, "<dunno>#{untokenized}</dunno>"]
            end
          end
        }
      }

      out = "\e[#{COLORS[:syntax]}m#{whitespace}"
      out << commented if commented.present?
      out << "*" if show
      out << col[:varname, varname]
      out << " = "
      out << col[objname.match?(/^[A-Z]/) ? :const : :variable, objname]
      out << "."
      out << col[:methodname, methodname]
      out << "("
      out << args.join(", ")
      out << ")"
      out << col[:castto, "::"]
      out << col[:cast, cast]
      next out unless commented.present?

      out.gsub(/\e\[[\d;]+m/, "\e[#{COLORS[:commented]}m")
    }.join("")
  end

  def initialize(commented, show, varname, objname, methodname, args, cast, code)
    @commented = commented.present?
    @show = show.present?
    @varname = varname.to_sym
    @objname = objname.to_sym
    @methodname = methodname.to_sym
    @args = Array.wrap(args)
    @cast = cast.to_sym
    @code = code
  end

  def show?
    show
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
