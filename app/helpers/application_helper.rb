module ApplicationHelper
  def render_modal(id, title, additional_classes="", &block)
    render layout: "layouts/modal", locals: { id: id, title: title, additional_classes: additional_classes } do
      block.call
    end
  end

  def posi_checker(str)
    if str&.starts_with?("+")
      "<span class=\"posi positive\">#{str}</span>".html_safe
    elsif str&.starts_with?("-")
      "<span class=\"posi negative\">#{str}</span>".html_safe
    else
      "<span class=\"posi neutral\">#{str}</span>".html_safe
    end
  end

  def pretty(language, file_path)
    file_contents = File.read("lib/assets/code_snippets/#{file_path}")
    file_contents.gsub!('`', '\\\\`')
    # "bsh", "c", "cc", "cpp", "cs", "csh", "cyc", "cv", "htm", "html", "java",
    #   "js", "m", "mxml", "perl", "pl", "pm", "py", "rb", "sh", "xhtml", "xml", "xsl"
    "<pre class=\"prettyprint lang-#{language} language-#{language}\">#{file_contents}</pre>"
  end

  def meta_title(str, include_name: true)
    str = "#{str} • Rocco Nicholls" if include_name
    content_for(:title) { CGI.escapeHTML(str.to_s).html_safe }
  end

  def meta_description(description)
    content_for(:description) { CGI.escapeHTML(description.to_s) }
  end

  def relative_time_in_words(time)
    distance_of_time_in_words(Time.current, time) + (time.future? ? " from now" : " ago")
  end

  def svg(svg_path, options={})
    Rails.cache.fetch("#{svg_path}.#{options.to_json}") do
      options[:nocomment] = true if options[:nocomment].nil?
      options[:title] ||= svg_path.split("/").last
      svg_html = inline_svg_tag("#{svg_path}.svg", options)

      if svg_html.include?("<!-- SVG file not found:")
        # Instead of rendering an empty SVG, this will attempt to lookup
        #   the image as a regular image, which will not only show a broken
        #   image on-screen, but it will add a js-console error as well, so
        #   we can see the attempted path for better debugging.
        image_tag svg_path, options
      else
        svg_html
      end
    end
  end
end
