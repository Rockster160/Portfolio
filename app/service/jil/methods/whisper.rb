class Jil::Methods::Whisper < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [Whisper]
  #   #notify(String:"Title" String?:"Body")
  #   #notifyAll(String:"Title" String?:"Body")

  def notify(title, body=nil)
    return if Rails.env.development?

    payload = build_payload(title, body)
    WebPushNotifications.send_to(@jil.user, payload, channel: :whisper)
  end

  def notifyAll(title, body=nil)
    return if Rails.env.development?

    payload = build_payload(title, body)
    users = broadcast_users
    WebPushNotifications.send_to_whisper(users, payload)
  end

  private

  def build_payload(title, body)
    payload = {
      title: title,
      icon:  "/whisper_favicon/whisper-detail.png",
    }
    payload[:body] = body if body.present?
    payload
  end

  def broadcast_users
    task = @jil.broadcast_task
    task.present? ? task.broadcast_users.to_a : [@jil.user]
  end
end
