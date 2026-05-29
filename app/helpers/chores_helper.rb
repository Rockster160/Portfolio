module ChoresHelper
  # An icon may be:
  #   * a plain emoji string (most chores)
  #   * a data URL (`data:image/png;base64,...`) — uploaded image
  #   * an external image URL (`https://...`)
  #   * inline SVG markup (`<svg ...>`) — pasted directly
  #   * empty / nil — fallback shown when fallback: true
  #
  # `fallback:` controls the placeholder. `:true` renders the broom emoji
  # at half opacity (so users see the input area), `:false` renders
  # nothing for inline contexts (lookahead chips). The grid + circle
  # cards pass a per-chore default (`📝` for one-offs, `🧹` otherwise) as
  # `fallback:`.
  def chore_icon_inline(chore, fallback: nil)
    raw_icon = chore.respond_to?(:icon) ? chore.icon.to_s : chore.to_s
    icon = raw_icon.strip

    return rendered_icon(icon) if icon.present?

    case fallback
    when false then ""
    when nil, true
      content_tag(:span, "🧹", class: "icon-placeholder",
                  title: "No icon set", "aria-hidden": "true")
    else
      content_tag(:span, fallback.to_s, class: "icon-glyph")
    end
  end

  private

  def rendered_icon(value)
    if value.start_with?("<svg")
      value.html_safe
    elsif value.start_with?("data:image/", "http://", "https://")
      image_tag(value, class: "icon-img", alt: "", loading: "lazy")
    else
      content_tag(:span, value, class: "icon-glyph")
    end
  end
end
