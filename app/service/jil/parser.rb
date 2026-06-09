class Jil::Parser
  attr_accessor :whitespace, :comment, :show, :varname, :objname, :methodname, :args, :cast, :inline_comment, :commented_depth

  TOKEN_REGEX = /__TOKEN\d+__/
  ESCAPED_REGEX = /
    (\r*\n\r*)*
    (?<whitespace>\s*)
    (?:
      (?<comment>(?:\#[\ \t]*)+)?
      (?<show>\*)?
      (?:(?<varname>[_a-z][_0-9A-Za-z]*)\s*=\s*)?\s*
      (?<objname>[_a-zA-Z][_0-9A-Za-z]*)
      \.(?<methodname>[_0-9A-Za-z]+[!?]?)
      (?<args>#{TOKEN_REGEX})
      ::(?<cast>[A-Z][_0-9A-Za-z]*)
      |
      \#\#\ ?(?<inline_comment>[^\n]*?)[\ \t]*(?=\r?\n|\z)
    )
  /xm
  COLORS = {
    syntax:     37,
    err:        31,
    comment:    "3;90",
    objname:    31,
    castto:     90,
    varname:    94,
    variable:   94,
    methodname: 37,
    const:      96,
    cast:       "3;36",
    constant:   35,
    string:     32,
    numeric:    33,
  }.freeze

  def self.from_code(code)
    breakdown(code)
  end

  def self.breakdown(code, tk=nil, &perline)
    escaped = code if tk.present?
    tk ||= Tokenizer.new(code)
    escaped ||= tk.tokenized_text

    results = []
    escaped.scan(ESCAPED_REGEX) do
      m = Regexp.last_match
      whitespace = m[:whitespace]

      line = if m[:inline_comment]
        ::Jil::Parser.new_comment(whitespace, m[:inline_comment])
      else
        comment = m[:comment]
        show = m[:show]
        varname = m[:varname]
        objname = m[:objname]
        methodname = m[:methodname]
        arg_code = m[:args]
        cast = m[:cast]

        args = tk.untokenize(arg_code, 1, unwrap: true).split(/,? +\r?\n?/).map { |nested|
          piece = tk.untokenize(nested)

          if piece.starts_with?("{") && piece.ends_with?("}")
            # Iterate through the nested functions as well.
            next breakdown(tk.untokenize(nested, 1), tk, &perline)
          end

          next piece if piece.match?(/\A".*?"\z/) # Do not parse strings in order to retain quotes.

          ::JSON.parse(piece) rescue piece # Parse object literal to extra raw nums, bools, etc.
        }

        ::Jil::Parser.new(whitespace, comment, show, varname, objname, methodname, args, cast)
      end

      results << (perline ? perline.call(line) : line)
    end
    results
  end

  def self.syntax_highlighting(code, _tk=nil)
    col = ->(color, text) { "\e[#{COLORS[color]}m#{text}\e[0m\e[#{COLORS[:syntax]}m" }

    breakdown(code) { |line|
      next col[:comment, "#{line.whitespace}## #{line.inline_comment}"] if line.inline_comment?

      [
        "\e[#{COLORS[:syntax]}m",
        line.whitespace,
        line.comment_prefix.presence,
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
              "#{line.whitespace}#{line.comment_prefix}}",
            ].join("\n")
          else
            case arg.to_s
            when /\A".*?"\z/
              col[:string, arg].gsub(/(#\{\s*)(\w+)(\s*\})/) { |_found|
                _, start, word, finish = Regexp.last_match.to_a
                [
                  col[:syntax, start],
                  col[:variable, word],
                  col[:syntax, finish],
                  "\e[#{COLORS[:string]}m",
                ].join
              }
            when /^\d+$/ then col[:numeric, arg]
            when /^(nil|null|true|false)$/ then col[:constant, arg] # reserved words
            when /^\w+$/ then col[:variable, arg]
            else col[:err, "<dunno>[Invalid String?]#{arg.inspect}</dunno>"]
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
    @commented_depth = (comment || "").count("#")
    @show = show.presence
    @varname = varname.to_sym
    @objname = objname.to_sym
    @methodname = methodname.to_sym
    @args = Array.wrap(args)
    @cast = cast.to_sym
  end

  def self.new_comment(whitespace, text)
    instance = allocate
    instance.send(:init_comment, whitespace, text)
    instance
  end

  def init_comment(whitespace, text)
    @whitespace = whitespace == "" ? nil : whitespace
    @inline_comment = text.to_s
    @args = []
    @commented_depth = 0
  end

  def shown?
    @show.present?
  end

  def commented?
    @commented_depth.to_i > 0
  end

  def inline_comment?
    !@inline_comment.nil?
  end

  def comment_prefix
    "# " * @commented_depth.to_i
  end

  def arg
    args.first
  end

  def to_s
    return "#{@whitespace}## #{@inline_comment}" if inline_comment?

    prefix = comment_prefix
    [
      @whitespace,
      prefix.presence,
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
    prefix = comment_prefix
    @args.map { |arg|
      next arg unless arg.is_a?(::Array)
      next "{}" if arg.empty?

      ["{", *arg, "#{@whitespace}#{prefix}}"].join("\n")
    }.join(", ")
  end
end
