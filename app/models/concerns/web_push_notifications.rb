# WebPushNotifications.send_to(User.me, { title: "Hello, World", body: "This is a message from Jarvis" })
module WebPushNotifications
  module_function

  def send_to(user, payload={})
    # return puts("\e[33m[WEBPUSH][#{user.username}] #{payload.inspect}\e[0m") if Rails.env.development?
    return "Failed to push - user not found" unless user.present?
    push_sub = user.primary_push_sub
    return "Failed to push - push_sub not set up" unless push_sub&.pushable?
    # example payload = {
    #   title: "Ardesian",
    #   body: "You have a new message!",
    #   count: 16,
    #   icon: "https://via.placeholder.com/100",
    #   url: "https://google.com"
    # }

    WebPush.payload_send(
      message: format_payload(user, payload).to_json,
      endpoint: push_sub.endpoint,
      p256dh: push_sub.p256dh,
      auth: push_sub.auth,
      vapid: {
        subject: "mailto:rocco@ardesian.com",
        public_key: ENV["PORTFOLIO_VAPID_PUB"],
        private_key: ENV["PORTFOLIO_VAPID_SEC"]
      }
    )
    return "Push success"
  rescue WebPush::Unauthorized => e
    "Failed to push - (WebPush Error) [#{e.class}] #{e}"
  end

  def update_count(user, count=nil)
    send_to(user, { count: count || user_counts(user })
  end

  def user_counts(user
    user.prompts.unanswered.reload.count
  end

  def format_payload(user, payload)
    extra_data = payload.deep_symbolize_keys!.slice!(*payload_keys)

    extra_data[:count] ||= user_counts(user

    payload[:data] ||= {}
    payload[:data].merge!(extra_data)

    payload
  end

  def payload_keys
    # https://developer.mozilla.org/en-US/docs/Web/API/notification
    [
      :title,
      # Visual Options
      :body, # <String>
      :icon, # <URL String>
      :image, # <URL String>
      :badge, # <URL String>
      :vibrate, # <Array of Integers>
      :sound, # <URL String>
      :dir, # <String of [auto | ltr | rtl]>
      # Behavioural Options
      :tag, # <String>
      :data, # <Anything>
      :requireInteraction, # <boolean>
      :renotify, # <Boolean>
      :silent, # <Boolean>
      # Both Visual & Behavioural Options
      :actions, # <Array of Strings> or <[{ action: "", title: "", icon: "" }]>
      # Information Option. No visual affect.
      :timestamp, # <Long>
    ]
  end
end
