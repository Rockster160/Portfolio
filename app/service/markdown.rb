class Markdown
  include ActionView::Helpers::TagHelper
  include ActionView::Helpers::UrlHelper

  attr_accessor :text

  def initialize(text, user: nil)
    @raw = text
    @text = text
    @tokens = {}
    @user = user
  end

  def to_html
    @text = ::ERB::Util.html_escape(@text)
    replace(
      /\r/ => "",
      /```(?<language>\w*)\n?(?<content>.*?)\n?```/m => code_block_wrapper,
      /^# (.*?)$/           => wrap('\1', :h1),
      /^## (.*?)$/          => wrap('\1', :h2),
      /^### (.*?)$/         => wrap('\1', :h3),
      /^#### (.*?)$/        => wrap('\1', :h4),
      /^##### (.*?)$/       => wrap('\1', :h5),
      /^###### (.*?)$/      => wrap('\1', :h6),
      /^\s*(-{3,}|={3,})\s*$/ => tag(:hr),
      /`(.*?)`/             => wrap('\1', :code),
      /\*(.*?)\*/           => wrap('\1', :strong),
      /_(.*?)_/             => wrap('\1', :em),
      /~(.*?)~/             => wrap('\1', :del),
      /!\[(.*?)\]\((.*?)\)/ => wrap(nil, :img, src: '\2', alt: '\1'),
      /\[(.*?)\]\((.*?)\)/  => wrap('\1', :a, href: '\2', target: :_blank),
      /\[(\w\s)*\]/                    => internal_link_wrapper,
      /^( *\* (?:.*?\n))+/m            => ul_wrapper,
      /^( *1[\.\)-:]? +(?:.*?\n))+/m   => ol_wrapper,
      /^ *(\|([^\n]+?\|)+ *(\n|\z))+/m => table_wrapper,
      /\n{3,}/m => ->(match) { "\n\n" + "</br>"*(match[0].length-2) },
    )

    # Wrap plain text in paragraphs
    rsub(/\n\n([^\n].*?[^\n]?)\n\n/, wrap('\1', :p) + "\n\n") # Wrap paragraphs
    @text.gsub!(/\n\n(.+)\z/m, wrap('\1', :p)) # Wrap last paragraph
    @text.gsub!(/\n/, tag(:br)) # Line breaks

    # linkify urls, but tokenize links and images so we don't double-link
    tokenize_tags(:a, :img)
    @text.gsub!(/\b(https?:\/\/\S+)\b/) { |found| wrap(found, :a, href: found) }

    # Tokenized blocks are stand-alone, so they don't need to be wrapped in paragraphs
    @text.gsub!(/<p>(%%\w{8}%%)<\/p>/, '\1')

    untokenize! # Replace tokenized content

    wrap(@text.strip.html_safe, :div, class: "markdown-container").html_safe
  end

  def replace(replacements)
    replacements.each do |pattern, replacement|
      if replacement.is_a?(Proc)
        @text.gsub!(pattern) { |found| replacement.call(Regexp.last_match) }
      else
        @text.gsub!(pattern, replacement)
      end
    end
  end

  def wrap(content, tag, **opts, &block)
    text = block.call(content.to_s) if block_given?
    text ||= content.join if content.is_a?(::Array)
    text ||= content.to_s
    content_tag(tag, text.html_safe, opts)
  end

  # Calls block with matching content and pair data
  # Expects the return to be the new data to input in place
  def replace_wrap(wrapper, tag=nil, **opts, &block)
    return replace_wrap(wrapper.to_h, content, &block) if wrapper.is_a?(::Array)
    return replace_wrap({ wrapper => wrapper }, content, &block) unless wrapper.is_a?(::Hash)

    wrapper.each do |pair_open, pair_close|
      last_idx = -1
      loop do
        pair_data = find_unescaped_pair(@text, pair_open, pair_close, after: last_idx)
        break if pair_data.nil?

        internal_range = (pair_data[:start_idx_end]+1...pair_data[:end_idx_start])
        external_range = (pair_data[:start_idx_start]..pair_data[:end_idx_end])

        if tag.present?
          # Removes wrapping pair
          @text[external_range] = content_tag(tag, pair_data[:content], opts)
        elsif block_given?
          @text[external_range] = block.call(pair_data[:content], pair_data)
        end
        last_idx = pair_data[:end_idx_end]
      end
    end
    @text
  end

  # returns [start_index, full_match]
  def find_unescaped_pair(str, pair_open, pair_close=nil, after: -1)
    pair_close ||= pair_open

    first_idx_start, first_idx_end, first_match = find_unescaped_index(str, pair_open, after: after)&.values
    return if first_idx_start.nil?

    next_idx_start, next_idx_end, last_match = find_unescaped_index(str, pair_close, after: first_idx_start)&.values
    return if next_idx_start.nil?

    {
      start_idx_start: first_idx_start,
      start_idx_end: first_idx_end,
      first_match: first_match,
      wrap_begin: str[first_idx_start..first_idx_end],
      content: str[first_idx_end+1...next_idx_start],
      wrap_end: str[next_idx_start..next_idx_end],
      last_match: last_match,
      end_idx_start: next_idx_start,
      end_idx_end: next_idx_end,
    }
  end

  # returns [start_index, end_index]
  def find_unescaped_index(str, char, after: -1)
    # if regex, don't escape
    str.enum_for(:scan, /(?:#{char.is_a?(String) ? Regexp.escape(char) : char})/m).find { |m|
      idx = Regexp.last_match.begin(0)
      next unless idx > after

      escapes = str[...idx][/\\*\z/].length
      return { start_idx: idx, end_idx: idx+Regexp.last_match.to_s.length-1, match: Regexp.last_match } if escapes.even?
    }
  end

  def code_block_wrapper
    ->(match) {
      language = match[:language].presence
      text = match[:content]
      case language&.to_sym
      when :csv
        begin
          csv = CSV.parse(text.strip).map { |row|
            wrap(row.map { |cell| wrap(cell.to_s.strip, :td) }, :tr)
          }
          tokenize(wrap(csv, :table))
        rescue CSV::MalformedCSVError
          tokenize(wrap(text.html_safe, :codeblock, data: { language: :csv }))
        end
      else
        tokenize(wrap(text.html_safe, :codeblock, data: { language: language }))
      end
    }
  end

  def ol_wrapper
    -> (match) {
      content = match[0]
      lines = content.split("\n").map { |li| wrap(li[/^\s*1[\.\)-:]? +(.*?)$/, 1] || li, :li) }
      wrap(lines, :ol) + "\n"
    }
  end

  def ul_wrapper
    ->(match) {
      content = match[0]
      lines = content.split("\n").map { |li| wrap(li[/^\s*\* (.*?)$/, 1] || li, :li) }
      wrap(lines, :ul) + "\n"
    }
  end

  def internal_link_wrapper
    -> (match) {
      next match[0] unless @user.present?

      name = match[0].strip
      page = @user.pages.ilike(name: name).take
      next match[0] if page.nil?

      wrap(page.name, :a, href: page_path(page))
    }
  end

  def table_wrapper
    ->(match) {
      rows = match[0].strip.split(/\s*\n\s*/).map { |row|
        row = row[/^\s*\|(.*?)\|\s*$/, 1] || row
        cells = row.split(/\|/).map { |cell| wrap(cell.to_s.strip.html_safe, :td) }
        wrap(cells, :tr)
      }
      wrap(rows, :table)
    }
  end

  def rsub(pattern, replacement)
    @text.sub!(pattern, replacement) while @text.match?(pattern)
  end

  def tokenize(content)
    generate_token.tap { |token| @tokens[token] = content }
  end

  def untokenize!
    @tokens.each { |token, content| @text.gsub!(token, content) }
  end

  def tokenize_tags(*tags)
    tags.each do |tag|
      @text.gsub!(/((?:<p>)?<#{tag}[^<]*?<\/#{tag}>(?:<\/p>)?)/) { |found| tokenize(found) }
    end
  end

  def generate_token
    loop do
      token = SecureRandom.hex(4)
      return "%%#{token}%%" unless @raw.include?(token)
    end
  end
end
