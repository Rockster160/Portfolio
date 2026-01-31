class Jil::Methods::PushNotification < Jil::Methods::Base
  PERMIT_ATTRS = [:tag, :title, :body].freeze

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
    ::WebPushNotifications.send_to(@jil.user, params(details))
  end

  def dismiss(tag)
    ::WebPushNotifications.dismiss(@jil.user, tag)
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

  private

  def params(details)
    @jil.cast(details, :Hash).slice(*PERMIT_ATTRS)
  end
end
