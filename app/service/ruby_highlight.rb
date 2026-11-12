require "ripper"

# Ruby source as highlighted HTML, cut into segments so each heredoc body can be
# drawn as a block of its own: plain code, then a heredoc, then code again.
# A heredoc whose terminator names JIL is highlighted as Jil and checked with
# Jil::Validator; any other heredoc is drawn as the string it is.
#
# Ripper does the lexing, so it is Ruby's own reading of the file. Its tokens
# come back in source order, heredoc bodies included, and join back into the
# source exactly; when they don't (a file Ripper gives up on part way), the
# whole thing is shown as plain text instead.
module RubyHighlight
  module_function

  Segment = Struct.new(:kind, :html, :delimiter, :jil, :error, keyword_init: true) {
    def heredoc? = kind == :heredoc
    def jil? = jil
    def valid? = error.nil?
  }

  # Called by name rather than on a receiver, so they read as Ruby's own verbs.
  SPECIAL = %w[
    require
    require_relative
    raise
    puts
    p
    pp
    print
    include
    extend
    attr_reader
    attr_writer
    attr_accessor
    private
    protected
    public
    module_function
    loop
  ].freeze
  BRACES = %i[on_lparen on_rparen on_lbrace on_rbrace on_lbracket on_rbracket on_tlambeg].freeze
  NUMBERS = %i[on_int on_float on_rational on_imaginary].freeze
  BLANKS = %i[on_sp on_ignored_sp on_nl on_ignored_nl].freeze

  def segments(code)
    tokens = Ripper.lex(code)
    return [Segment.new(kind: :code, html: escape(code))] unless tokens.sum("") { |token| token[2] } == code

    Lexed.new(tokens).segments
  end

  def escape(text)
    ERB::Util.html_escape(text)
  end

  # A token's closing newline goes outside its span, so a segment can drop the
  # newline it ends on.
  def span(kind, text)
    return escape(text) if kind.nil?
    return "#{span(kind, text.chomp)}\n" if text.end_with?("\n") && text != "\n"

    "<span class=\"rh-#{kind}\">#{escape(text)}</span>"
  end

  # One pass over Ripper's tokens. A heredoc's body starts after the line its
  # opener is on and runs to its terminator; two openers on one line have
  # their bodies one after the other, in the order they were opened.
  class Lexed
    def initialize(tokens)
      @tokens = tokens
      @segments = []
      @html = +""
      @opened = []
      @strings = []
    end

    def segments
      index = 0
      while index < @tokens.length
        _position, type, text = @tokens[index]
        if @body
          index = read_body(index)
          next
        end

        @html << RubyHighlight.span(kind_of(index), text)
        @opened << heredoc_opener(text) if type == :on_heredoc_beg
        @body = true if @opened.any? && line_end?(type, text)
        index += 1
      end
      flush
      @segments
    end

    private

    def heredoc_opener(text)
      { delimiter: text[/[A-Za-z_]\w*/].to_s, squiggly: text.start_with?("<<~") }
    end

    def line_end?(type, text)
      %i[on_nl on_ignored_nl on_comment].include?(type) && text.end_with?("\n")
    end

    # Collects the raw body up to the terminator, which stays with the code
    # that follows so the block is only the body itself.
    def read_body(index)
      opener = @opened.shift
      body = +""
      while index < @tokens.length && @tokens[index][1] != :on_heredoc_end
        body << @tokens[index][2]
        index += 1
      end
      flush
      @segments << heredoc_segment(body, opener)
      if index < @tokens.length
        @html << RubyHighlight.span(:string, @tokens[index][2])
        index += 1
      end
      @body = @opened.any?
      index
    end

    def heredoc_segment(body, opener)
      body = body.chomp
      jil = opener[:delimiter].match?(/JIL/i)
      error = (jil_error(opener[:squiggly] ? dedent(body) : body) if jil)
      html = jil ? JilHighlight.html(body) : RubyHighlight.span(:string, body)
      Segment.new(kind: :heredoc, html: html, delimiter: opener[:delimiter], jil: jil, error: error)
    end

    def jil_error(body)
      ::Jil::Validator.validate!(body)
      nil
    rescue StandardError => e
      e.message.presence || e.class.name
    end

    def dedent(body)
      indent = body.lines.reject { |line| line.strip.empty? }.map { |line| line[/\A */].length }.min.to_i
      body.lines.map { |line| line.sub(/\A {0,#{indent}}/, "") }.join
    end

    def flush
      return if @html.empty?

      @segments << Segment.new(kind: :code, html: @html.chomp)
      @html = +""
    end

    def kind_of(index)
      _position, type, text = @tokens[index]
      case type
      when :on_heredoc_beg then :string
      when :on_tstring_beg, :on_backtick, :on_qwords_beg, :on_words_beg, :on_qsymbols_beg, :on_symbols_beg
        @strings << :string
        :string
      when :on_tstring_end
        @strings.pop
        :string
      when :on_regexp_beg
        @strings << :regexp
        :regexp
      when :on_regexp_end
        @strings.pop
        :regexp
      when :on_tstring_content then @strings.last || :string
      when :on_embexpr_beg, :on_embexpr_end then :interp
      when :on_comment, :on_embdoc_beg, :on_embdoc, :on_embdoc_end then :comment
      when :on_const then :const
      when :on_ivar, :on_gvar, :on_cvar then :ivar
      when :on_label, :on_symbeg then :symbol
      when :on_kw then keyword_kind(index, text)
      when :on_ident then ident_kind(index, text)
      when :on_op, :on_period, :on_comma, :on_semicolon then :op
      else
        return :num if NUMBERS.include?(type)
        return :brace if BRACES.include?(type)

        nil
      end
    end

    def keyword_kind(index, text)
      return :symbol if previous_type(index) == :on_symbeg

      case text
      when "nil" then :nil
      when "true", "false" then :bool
      when "self" then :self
      else :kw
      end
    end

    def ident_kind(index, text)
      before = previous_type(index)
      return :symbol if before == :on_symbeg
      return :def if before == :on_kw && previous_text(index) == "def"
      return :call if before == :on_period
      return :special if SPECIAL.include?(text)
      return :call if next_type(index) == :on_lparen

      nil
    end

    def previous_type(index) = neighbor(index, -1)&.at(1)
    def previous_text(index) = neighbor(index, -1)&.at(2)
    def next_type(index) = @tokens[index + 1]&.at(1)

    # The nearest token that isn't blank space, so `def  name` still reads as one.
    def neighbor(index, step)
      index += step
      index += step while index.between?(0, @tokens.length - 1) && BLANKS.include?(@tokens[index][1])
      index.between?(0, @tokens.length - 1) ? @tokens[index] : nil
    end
  end
end
