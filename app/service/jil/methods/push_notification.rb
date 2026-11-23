class Jil::Methods::PushNotification < Jil::Methods::Base
  PERMIT_ATTRS = [:tag, :title, :body].freeze
  # The most buttons iOS shows on one notification.
  MAX_BUTTONS = 4

  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [PushNotification]
  #   #notify(content(PushNotificationData))
  #   #dismiss(String:Tag)
  # *[PushNotificationData]
  #   #tag(String)
  #   #title(String)
  #   #body(Text)
  #   #buttons(content(PushNotificationButton))
  # *[PushNotificationButton]
  #   #button(String:"Label" String:"Trigger" BR Hash?:"Data" Boolean?(false):"Ask for text")

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case method_sym
    when *PERMIT_ATTRS
      case token_class(line.objname)
      when :PushNotificationData
        send(method_sym, *evalargs(line.args))
      else fallback(line)
      end
    else fallback(line)
    end
  end

  # [PushNotification]

  def notify(details)
    details = @jil.cast(details, :Hash)
    payload = params(details).merge(phone_buttons(details[:buttons]))
    ::WebPushNotifications.send_to(@jil.user, payload, channel: :jarvis)
  end

  # Takes nothing away. Removing a notification from a device needs a push that
  # shows nothing, and iOS revokes a subscription for exactly that (see
  # WebPushNotifications.send_to). Kept so tasks that call it still run.
  def dismiss(_tag)
    nil
  end

  # [PushNotificationData]

  def tag(text)
    { tag: text }
  end

  def title(text)
    { title: text }
  end

  def body(text)
    { body: text }
  end

  # Kept as given until notify, which turns them into what the phone shows.
  def buttons(list)
    { buttons: Array.wrap(list).flatten.select { |button| button.is_a?(Hash) } }
  end

  # [PushNotificationButton]

  # A button on the notification in the phone app. Pressing it fires `trigger`
  # with `data`, plus `text` when the button asks for some; nothing opens.
  def button(label, trigger, data=nil, ask=nil)
    {
      label:   label.to_s,
      trigger: trigger.to_s,
      data:    @jil.cast(data, :Hash),
      ask:     ask == true,
    }
  end

  private

  def params(details)
    details.slice(*PERMIT_ATTRS)
  end

  # What the phone shows (`actions`) and what each one does when pressed
  # (`button_actions`, keyed by the action's id). Both ride in `data`, which a
  # browser never draws buttons from, since it has nothing to do when pressed.
  def phone_buttons(list)
    list = Array.wrap(list).select { |button| button.is_a?(Hash) && button[:trigger].present? }
    return {} if list.empty?

    list = list.first(MAX_BUTTONS).each_with_index.map { |button, index| ["button_#{index}", button] }
    actions = list.map { |id, button|
      { id: id, title: button[:label], input: (true if button[:ask]) }.compact
    }
    pressed = list.to_h.transform_values { |button|
      { kind: :trigger, value: button[:trigger], data: button[:data] }
    }
    { data: { actions: actions, button_actions: pressed } }
  end
end
