class Jil::Methods::Whisper < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [Whisper]
  #   #notifySelf(String:"Title" String?:"Body" String?:"Tag")
  #   #notifyAll(String:"Title" String?:"Body" String?:"Tag")
  #   #dismiss(String:"Tag")

  def notifySelf(title, body=nil, tag=nil)
    payload = { title: title, users: [@jil.user] }
    payload[:body] = body if body.present?
    payload[:tag] = tag if tag.present?

    ::WebPushNotifications.send_to_whisper(payload)
  end

  def notifyAll(title, body=nil, tag=nil)
    payload = { title: title }
    payload[:body] = body if body.present?
    payload[:tag] = tag if tag.present?

    ::WebPushNotifications.send_to_whisper(payload)
  end

  def dismiss(tag)
    ::WebPushNotifications.dismiss_whisper(tag)
  end
end
