module ChoresHelper
  # Drops trailing ".0" on whole-number multipliers — "2×" not "2.0×",
  # "1.5×" still renders as "1.5×". Applies to both the hot-strip and
  # the on-card hot-badge.
  def format_multiplier(value)
    return "" if value.nil?

    f = value.to_f
    f == f.to_i ? f.to_i.to_s : ("%g" % f)
  end

  # The balance pill at the top of every chores page shows today's
  # earnings. Lazily compute it so the helper works on whatever page
  # renders the header — Grid / Today already loaded the breakdown
  # (`@balance_today`); Balance / History haven't, so fall through to
  # the model.
  def today_earnings_for_header
    return @balance_today if defined?(@balance_today) && @balance_today

    day = (defined?(@day) && @day) || ChoreDay.current(current_user)
    current_user.chore_balance_breakdown(day)[:today_earnings]
  end

  # `1,234p` with thousands delimiter. Unit "p" never pluralizes (it's
  # an abbreviation like "kg"). Pass `sign: :explicit` to surface a
  # leading "+" / "-" for entry rows.
  def format_pebbles(value, sign: :default)
    n = value.to_i
    formatted = number_with_delimiter(n.abs)
    prefix = case sign
             when :explicit then (n.positive? ? "+" : n.negative? ? "−" : "")
             else (n.negative? ? "−" : "")
             end
    "#{prefix}#{formatted}p"
  end

  # `1,234` with thousands delimiter — bare count, no pebble suffix.
  # Used for totals (history summary right column, etc.).
  def format_count(value)
    number_with_delimiter(value.to_i)
  end

  # An icon may be:
  #   * a plain emoji string (most chores)
  #   * a Tabler Icons class name (`ti-dev-docker`) — rendered as `<i class="ti …">`
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
    elsif value.start_with?("ti-")
      content_tag(:i, "", class: "ti #{value} icon-ti", "aria-hidden": "true")
    else
      content_tag(:span, value, class: "icon-glyph")
    end
  end
end
