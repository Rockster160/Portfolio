class Jil::Methods::Widget < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [Widget]
  #   #set(String:"Key" content(Hash|Keyval [Keyval.new]))::Hash
  #   #merge(String:"Key" content(Hash|Keyval [Keyval.new]))::Hash
  #   #get(String:"Key")::Hash
  #   #clear(String:"Key")::Boolean
  #   #reload::Boolean

  # Replaces what the phone's panel widget named `key` shows. The keys are the
  # app's: title, subtitle, icon, color, background, text, value, rows, buttons,
  # chart, image_url, svg, url, action, refresh_after.
  def set(key, content)
    panel = find_or_build(key)
    panel.update!(content: @jil.cast(content, :Hash).deep_stringify_keys)
    panel.content
  end

  # Changes some keys and keeps the rest, for a task that only knows the
  # state of one button.
  def merge(key, content)
    panel = find_or_build(key)
    changes = @jil.cast(content, :Hash).deep_stringify_keys
    panel.update!(content: panel.content.to_h.deep_merge(changes))
    panel.content
  end

  def get(key)
    @jil.user.app_panels.find_by(key: ::AppPanel.normalize_key(key))&.content || {}
  end

  def clear(key)
    @jil.user.app_panels.where(key: ::AppPanel.normalize_key(key)).destroy_all.any?.tap { |cleared|
      ::AppPush.reload_widgets_later([@jil.user]) if cleared
    }
  end

  # Asks every widget on the person's phones to draw again, for data a widget
  # reads that nothing here wrote (a list it shows, an agenda).
  def reload # rubocop:disable Naming/PredicateMethod
    ::AppPush.reload_widgets_later([@jil.user])
    true
  end

  private

  def find_or_build(key)
    normalized = ::AppPanel.normalize_key(key)
    raise ::Jil::ExecutionError, "A widget needs a key" if normalized.nil?

    @jil.user.app_panels.find_or_initialize_by(key: normalized)
  end
end
