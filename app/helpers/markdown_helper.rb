module MarkdownHelper
  class RenderWithTargetBlank < Redcarpet::Render::HTML
    def link(link, title, content)
      "<a href='#{link}' target='_blank'>#{content}</a>"
    end
  end

  def renderer
    @renderer ||= begin
      Redcarpet::Markdown.new(
        # Redcarpet::Render::HTML.new(hard_wrap: true),
        RenderWithTargetBlank.new(hard_wrap: true),
        no_intra_emphasis: true,
        tables: true,
        fenced_code_blocks: true,
        disable_indented_code_blocks: true,
        autolink: true,
        strikethrough: true,
        lax_spacing: true,
        space_after_headers: true,
        superscript: true,
        # underline: true, # breaks italics, should use double underscore for underline
        highlight: true,
        quote: true,
        footnotes: true,
      )
    end
  end

  def render_md(markdown)
    raw postprocess(renderer.render(preprocess(markdown)))
  end

  def preprocess(markdown)
    markdown
      .then { |content| fix_emphasis(content) }
      .then { |content| leading_spaces(content) }
  end

  def postprocess(html)
    html
      .then { |content| render_linked_pages(content) }
  end

  def fix_emphasis(content)
    # Stupid standard markdown does *italics* and **bold** and _italics_ and __bold__
    # This fixes it so that it is *bold* and _italics_ and **bold** and __italics__
    content.gsub(/__\b|\b__/, "_").gsub(/(\s)\*\b|\b\*(\s)/, '\1**\2')
  end

  def leading_spaces(content)
    # BUG: Should not convert inside of a code block
    content.gsub(/^ +/) { |spaces| "&nbsp;" * spaces.length }
  end

  def render_linked_pages(content)
    content.gsub(/\[(.*?)\]/) do |match|
      page_title = $1
      page = current_user.pages.ilike(name: page_title).take
      if page
        link_to(page.name, page_path(page))
      else
        match
      end
    end.html_safe
  end
end
