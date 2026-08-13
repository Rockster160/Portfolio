class Jil::Methods::Whisper < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [Whisper]
  #   #notifySelf(String:"Title" String?:"Body" String?:"Tag" String?:"Icon")
  #   #notifyAll(String:"Title" String?:"Body" String?:"Tag" String?:"Icon")
  #   #dismiss(String:"Tag")

  # `icon` is a root-relative path under public/ — the service worker fetches it
  # by URL, so an /assets/ digest path or a data: URI will not do. Blank falls
  # through to the Whisper default in send_to_whisper.
  def notifySelf(title, body=nil, tag=nil, icon=nil)
    payload = { title: title, users: [@jil.user] }
    payload[:body] = body if body.present?
    payload[:tag] = tag if tag.present?
    payload[:icon] = icon if icon.present?

    ::WebPushNotifications.send_to_whisper(payload)
  end

  def notifyAll(title, body=nil, tag=nil, icon=nil)
    payload = { title: title }
    payload[:body] = body if body.present?
    payload[:tag] = tag if tag.present?
    payload[:icon] = icon if icon.present?

    ::WebPushNotifications.send_to_whisper(payload)
  end

  def dismiss(tag)
    ::WebPushNotifications.dismiss_whisper(tag)
  end
end
