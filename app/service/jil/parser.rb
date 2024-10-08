class Jil::Parser
  attr_accessor :whitespace, :comment, :show, :varname, :objname, :methodname, :args, :cast

  TOKEN_REGEX = /\|\|TOKEN\d+\|\|/
  ESCAPED_REGEX = /
    (\r*\n\r*)*
    (?<whitespace>\s*)
    (?<comment>\#\s*)?
    (?<show>\*)?
    (?:(?<varname>[_a-z][_0-9A-Za-z]*)\s*=\s*)?\s*
    (?<objname>[_a-zA-Z][_0-9A-Za-z]*)
    \.(?<methodname>[_0-9A-Za-z]+[!?]?)
    (?<args>#{TOKEN_REGEX})
    ::(?<cast>[A-Z][_0-9A-Za-z]*)
  /xm
  COLORS = {
    syntax: 37,
    err: 31,
    comment: "3;90",
    objname: 31,
    castto: 90,
    varname: 94,
    variable: 94,
    methodname: 37,
    const: 96,
    cast: "3;36",
    constant: 35,
    string: 32,
    numeric: 33,
  }.freeze

  def self.from_code(code)
    breakdown(code)
  end

  def self.breakdown(code, tk=nil, &perline)
    escaped = code if tk.present?
    tk ||= NewTokenizer.new(code)
    escaped ||= tk.tokenized_text

    escaped.scan(ESCAPED_REGEX)&.map.with_index { |(whitespace, comment, show, varname, objname, methodname, arg_code, cast), idx|
      args = tk.untokenize(arg_code, 1, unwrap: true).split(/,? +\r?\n?/).map { |nested|
        piece = tk.untokenize(nested)

        if piece.starts_with?("{") && piece.ends_with?("}")
          # Iterate through the nested functions as well.
          next breakdown(tk.untokenize(nested, 1), tk, &perline)
        end

        next piece if piece.match?(/\A\".*?\"\z/) # Do not parse strings in order to retain quotes.

        ::JSON.parse(piece) rescue piece # Parse object literal to extra raw nums, bools, etc.
      }

      line = ::Jil::Parser.new(whitespace, comment, show, varname, objname, methodname, args, cast)

      perline ? perline.call(line) : line
    }
  end

  def self.syntax_highlighting(code, tk=nil)
    col = ->(color, text) { "\e[#{COLORS[color]}m#{text}\e[0m\e[#{COLORS[:syntax]}m" }

    breakdown(code) { |line|
      [
        "\e[#{COLORS[:syntax]}m",
        line.whitespace,
        line.comment,
        line.show,
        col[:varname, line.varname],
        " = ",
        col[line.objname.match?(/^[A-Z]/) ? :const : :variable, line.objname],
        ".",
        col[:methodname, line.methodname],
        "(",
        line.args.map { |arg|
          if arg.is_a?(::Array)
            next "{}" if arg.empty?

            [
              "{",
              *arg,
              "#{line.comment}#{line.whitespace}}",
            ].join("\n")
          else
            case arg.to_s
            when /\A\".*?\"\z/
              col[:string, arg].gsub(/(#\{\s*)(\w+)(\s*\})/) { |found|
                _, start, word, finish = Regexp.last_match.to_a
                [
                  col[:syntax, start],
                  col[:variable, word],
                  col[:syntax, finish],
                  "\e[#{COLORS[:string]}m",
                ].join
              }
            when /^\d+$/
              col[:numeric, arg]
            when /^(nil|null|true|false)$/
              col[:constant, arg]
            when /^\w+$/
              col[:variable, arg]
            else
              col[:err, "<dunno>[Invalid String?]#{arg.inspect}</dunno>"]
            end
          # else col[:err, "<dunno>[#{arg.class}]#{arg.inspect}</dunno>"]
          end
        }.join(", "),
        ")",
        col[:castto, "::"],
        col[:cast, line.cast],
      ].join.tap { |raw|
        raw.gsub!(/\e\[[\d;]+m/, "\e[#{COLORS[:comment]}m") if line.commented?
      }
    }.join("\n")
  end

  def initialize(whitespace, comment, show, varname, objname, methodname, args, cast)
    @whitespace = whitespace == "" ? nil : whitespace
    @comment = comment.presence
    @show = show.presence
    @varname = varname.to_sym
    @objname = objname.to_sym
    @methodname = methodname.to_sym
    @args = Array.wrap(args)
    @cast = cast.to_sym
  end

  def shown?
    @show.present?
  end

  def commented?
    @comment.present?
  end

  def arg
    args.first
  end

  def to_s
    [
      @whitespace,
      @comment,
      @show,
      @varname,
      " = ",
      @objname,
      ".",
      @methodname,
      "(",
      args_to_s,
      ")",
      "::",
      @cast,
    ].compact.join
  end

  def args_to_s
    @args.map { |arg|
      next arg unless arg.is_a?(::Array)
      next "{}" if arg.empty?

      ["{", *arg, "#{@comment}#{@whitespace}}"].join("\n")
    }.join(", ")
  end
end
