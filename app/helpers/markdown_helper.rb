module MarkdownHelper
  def renderer
    # @renderer ||= Redcarpet::Markdown.new(CustomMarkdownRenderer, autolink: true, tables: true)
    @renderer ||= Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(hard_wrap: true))
  end

  def render_md(markdown)

    raw postprocess(renderer.render(preprocess(markdown)))
  end

  def preprocess(markdown)
    markdown.then { |content| fix_emphasis(content) }
  end

  def postprocess(text)
    text.then { |content| render_linked_pages(content) }
  end

  def fix_emphasis(content)
    # Stupid standard markdown does *italics* and **bold** and _italics_ and __bold__
    # This fixes it so that it is *bold* and _italics_ and **bold** and __italics__
    content.gsub(/__\b|\b__/, "_").gsub(/(\s)\*\b|\b\*(\s)/, '\1**\2')
  end

  def render_linked_pages(content)
    content.gsub(/\[(.*?)\]/) do |match|
      page_title = $1
      page = current_user.pages.ilike(title: page_title).take
      if page
        link_to(page.title, page_path(page))
      else
        match
      end
    end.html_safe
  end
end
