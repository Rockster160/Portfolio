require "strscan"

# Jil source as highlighted HTML, for a Jil heredoc inside a production script.
# It colors what Jil::Parser reads - `name = Object.method(args)::Cast`, `##`
# comments, `#` to comment a line out - one token at a time, so a body that
# is only part of a task, or that Ruby interpolates into, still draws.
module JilHighlight
  module_function

  TOKENS = [
    [:comment,  /\#\#[^\n]*/],
    [:string,   /"(?:[^"\\]|\\.)*"/],
    [:cast,     /::[A-Z]\w*/],
    [:num,      /-?\d+(?:\.\d+)?\b/],
    [:bool,     /\b(?:true|false)\b/],
    [:nil,      /\b(?:nil|null)\b/],
    [:const,    /[A-Za-z_]\w*(?=\.\w)/],
    [:call,     /(?<=\.)\w+[!?]?/],
    [:variable, /[a-z_]\w*/],
    [:brace,    /[(){}\[\]]/],
    [:op,       /[=,.*#]/],
  ].freeze
  INTERPOLATION = /\#\{[^}]*\}/

  def html(source)
    scanner = StringScanner.new(source)
    out = +""
    until scanner.eos?
      kind, matched = TOKENS.lazy.filter_map { |name, pattern|
        found = scanner.scan(pattern)
        [name, found] if found
      }.first
      if matched
        out << (kind == :string ? string(matched) : RubyHighlight.span(kind, matched))
      else
        out << RubyHighlight.escape(scanner.getch)
      end
    end
    out
  end

  # Strings keep their `#{}` visible, since that is where a variable goes in.
  def string(text)
    parts = text.split(/(#{INTERPOLATION})/o)
    parts.map { |part|
      RubyHighlight.span(part.match?(/\A#{INTERPOLATION}\z/o) ? :interp : :string, part)
    }.join
  end
end
