module QuickActionsHelper
  def mini_widgets(widget)
    render partial: "mini_widgets", locals: { widget: widget }
  end

  def img(filename)
    emoji("<img src='/#{filename}.png'/>")
  end

  def emoji(icon)
    "<i class=\"emoji\">#{icon}</i>"
  end

  def emoji_stack(*icons)
    "<div class=\"emoji-stack\">#{icons.map { |i| emoji(i) }.join("")}</div>"
  end

  def clean_md(md)
    md.to_s.gsub(/\[ico (.*?)\]/) { |f| f }
  end

  def mrkdwn(md)
    md.to_s
      .gsub(/([\p{So}\p{Sk}\p{Sm}\p{Sc}\p{S}\p{C}]+)/) { |f| "<i class=\"emoji\">#{Regexp.last_match(1)}</i>" }
      .gsub(/\[ico (.*?)(( \w+: .*?;)*)\]/) { |f| "<i class=\"emoji ti ti-#{Regexp.last_match(1)}\" style=\"#{Regexp.last_match(2)}\"></i>" }
      .gsub(/\[img (.*?)\]/) { |f| emoji("<img src=\"./#{Regexp.last_match(1)}.png\"/>") }
      .html_safe
  end

  def parse_blocks(blocks)
  end
end
