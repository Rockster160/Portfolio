class Jil::Methods::Whisper < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [Whisper]
  #   #notifySelf(String:"Title" String?:"Body")
  #   #notifyAll(String:"Title" String?:"Body")

  def notifySelf(title, body=nil)
    payload = { title: title, users: [@jil.user] }
    payload[:body] = body if body.present?

    ::WebPushNotifications.send_to_whisper(payload)
  end

  def notifyAll(title, body=nil)
    payload = { title: title }
    payload[:body] = body if body.present?

    ::WebPushNotifications.send_to_whisper(payload)
  end
end
