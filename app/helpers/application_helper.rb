module ApplicationHelper
  def render_modal(id, title, additional_classes="", &block)
    render layout: "layouts/modal",
      locals: { id: id, title: title, additional_classes: additional_classes } do
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
    file_contents.gsub!("`", '\\\\`')
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

  def format_duration(seconds)
    return "--" if seconds.nil?

    if seconds < 1
      "#{(seconds * 1000).round}ms"
    elsif seconds < 60
      "#{seconds.round(2)}s"
    elsif seconds < 3600
      mins = (seconds / 60).floor
      secs = (seconds % 60).round
      "#{mins}m #{secs}s"
    else
      hours = (seconds / 3600).floor
      mins = ((seconds % 3600) / 60).round
      "#{hours}h #{mins}m"
    end
  end

  def i(type)
    "<i class=\"fa fa-#{type}\"></i>".html_safe
  end

  def fa(type)
    # Font Awesome
    "<i class=\"fa fa-#{type.to_s.gsub("_", "-")}\"></i>".html_safe
  end

  def svg(svg_path, options={})
    Rails.cache.fetch("#{svg_path}.#{options.to_json}") do
      options[:nocomment] = true if options[:nocomment].nil?
      options[:title] ||= svg_path.to_s.split("/").last
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

  def execution_auth_link(execution)
    label = execution.auth_label
    record = execution.auth_record

    case record
    when ::Task   then link_to(label, jil_task_path(record.id), class: "auth-link task")
    when ::ApiKey then link_to(label, edit_api_key_path(record.id), class: "auth-link api-key")
    else label
    end
  end

  # Render an icon reference — the shared vocabulary the IconPool speaks, in
  # Ruby. One of:
  #
  #   * an emoji (or any short glyph)  — "🏢"
  #   * a Tabler icon class            — "ti-flame"
  #   * a household upload             — "hicon:12"
  #   * inline SVG markup              — "<svg …>"
  #   * an image                       — a data: URL or an https: one
  #
  # This was `ChoresHelper#rendered_icon` and moved here the moment a second
  # feature needed it. Blank gives back nil so the caller decides what an
  # absent icon looks like — a broom on a chore, a company's initials on an
  # application.
  def icon_ref_tag(value)
    icon = value.to_s.strip
    return nil if icon.blank?

    if icon.start_with?("<svg")
      icon.html_safe
    elsif icon.start_with?("hicon:")
      household_icon_tag(icon)
    elsif icon.start_with?("data:image/", "http://", "https://")
      image_tag(icon, class: "icon-img", alt: "", loading: :lazy)
    elsif icon.start_with?("ti-")
      content_tag(:i, "", class: "ti #{icon} icon-ti", "aria-hidden": "true")
    else
      content_tag(:span, icon, class: "icon-glyph")
    end
  end

  # `hicon:<id>` points at a HouseholdIcon row whose image_data is a base64
  # data URL. A dangling ref — someone deleted the icon — gives back nil, so
  # the caller's own fallback takes over rather than a broken image.
  def household_icon_tag(ref)
    icon = ::HouseholdIcon.find_by(id: ref.delete_prefix("hicon:").to_i)
    return nil if icon&.image_data.blank?

    image_tag(icon.image_data, class: "icon-img", alt: "", loading: :lazy)
  end

  def safeparse_time(time, fallback=::Time.current)
    return fallback if time.blank?

    if time.is_a?(String)
      begin
        return Time.zone.parse(time)
      rescue StandardError
        return fallback
      end
    else
      time
    end
  end
end
