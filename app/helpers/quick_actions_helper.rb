module QuickActionsHelper
  def widget(data, **extra_data, &block)
    page_tag = data[:type]&.to_sym == :page
    tag = page_tag ? :a : :div
    wrapper_data = {
      href: page_tag ? data[:page] : nil,
      target: page_tag ? :_blank : nil,
    }.compact

    content_tag(tag, { class: "widget-holder", data: extra_data }.merge(wrapper_data)) do
      concat content_tag(:div, "❌", class: "delete-widget hidden")
      concat(content_tag(:div, class: :widget, data: data.except(:buttons)) do
        if block_given?
          block.call
        elsif data[:display].present?
          data[:display] # Only used for a placeholder
        elsif
          concat(content_tag(:span, class: :title) { mrkdwn(data[:title]) })
          if data[:subtitle].present?
            concat(content_tag(:span, class: :subtitle) { mrkdwn(data[:subtitle]) })
          end
        end
      end)
    end
  end

  def img(filename)
    emoji("<img src='/#{filename}.png'/>".html_safe)
  end

  def emoji(icon, extra_classes=nil, style: nil)
    content_tag(:i, class: "emoji #{extra_classes}", style: style) do
      icon
    end
  end

  def clean_md(md)
    md.to_s.gsub(/\[ico (.*?)\]/) { |f| f }
  end

  def mrkdwn(md)
    md.to_s
      .gsub(/([\p{So}\p{Sk}\p{Sm}\p{Sc}\p{S}\p{C}]+)/) { |f|
        emoji(Regexp.last_match(1))
      }.gsub(/\[ico (.*?)(( \w+: .*?;)*)\]/) { |f|
        emoji(nil, "ti ti-#{Regexp.last_match(1)}", style: Regexp.last_match(2))
      }.gsub(/\[img (.*?)\]/) { |f|
        img(Regexp.last_match(1))
      }.html_safe
  end
end
