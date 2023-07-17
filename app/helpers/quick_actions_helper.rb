module QuickActionsHelper
  def mini_widgets(id, &block)
    render partial: "mini_widgets", locals: { id: id, items: block&.call }
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
end
