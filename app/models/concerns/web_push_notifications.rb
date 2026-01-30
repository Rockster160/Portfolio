# WebPushNotifications.send_to(User.me, { title: "Hello, World", body: "This is a message from Jarvis" })
# WebPushNotifications.send_to(User.me, { title: "Hello" }, channel: :whisper)
# WebPushNotifications.broadcast_to_channel([user1, user2], { title: "Hello" }, channel: :whisper)
# WebPushNotifications.send_to_whisper({ title: "Fed!" }) # sends to all whisper subscribers
# WebPushNotifications.send_to_whisper({ title: "Fed!", users: [user1] }) # sends to specific users
module WebPushNotifications
  module_function

  def send_to(user, payload={}, channel: :jarvis)
    return puts("\e[33m[WEBPUSH][#{user.username}] #{payload.inspect}\e[0m") if Rails.env.development?
    return "Failed to push - user not found" if user.blank?

    push_sub = user.primary_push_sub(channel: channel)
    return "Failed to push - push_sub not set up" unless push_sub&.pushable?
    # example payload = {
    #   title: "Ardesian",
    #   body: "You have a new message!",
    #   count: 16,
    #   icon: "https://via.placeholder.com/100",
    #   url: "https://google.com"
    # }

    # Temp stub to see if empty notifications are what's breaking things.
    # Allow dismiss payloads through (they have no title but need to be sent)
    payload = payload.deep_symbolize_keys
    return if payload[:title].blank? && !payload[:dismiss]

    WebPush.payload_send(
      message:  format_payload(user, payload).to_json,
      endpoint: push_sub.endpoint,
      p256dh:   push_sub.p256dh,
      auth:     push_sub.auth,
      vapid:    {
        subject:     "mailto:rocco@ardesian.com",
        public_key:  ENV.fetch("PORTFOLIO_VAPID_PUB", nil),
        private_key: ENV.fetch("PORTFOLIO_VAPID_SEC", nil),
      },
    )
    return "Push success"
  rescue WebPush::Unauthorized => e
    "Failed to push - (WebPush Error) [#{e.class}] #{e}"
  end

  def update_count(user, count=nil)
    send_to(user, { count: count || user_counts(user) })
  end

  def user_counts(user)
    user.prompts.unanswered.reload.count
  end

  def format_payload(user, payload)
    extra_data = payload.deep_symbolize_keys!.slice!(*payload_keys)

    extra_data[:count] ||= user_counts(user)

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
      # Custom
      :dismiss, # <Boolean> - used to dismiss notifications by tag
    ]
  end

  # Broadcast to multiple users on a specific channel
  def broadcast_to_channel(users, payload={}, channel:)
    Array.wrap(users).map { |user| send_to(user, payload, channel: channel) }
  end

  # Convenience method for Whisper notifications - sends to all whisper subscribers by default
  def send_to_whisper(payload={})
    payload = { title: payload } if payload.is_a?(::String)
    payload = payload.deep_symbolize_keys
    payload[:icon] ||= "/whisper_favicon/whisper-detail.png"

    users = payload.delete(:users) || all_whisper_subscribers
    broadcast_to_channel(users, payload, channel: :whisper)
  end

  # Dismiss a Whisper notification by tag on all subscribers' devices
  def dismiss_whisper(tag)
    broadcast_to_channel(all_whisper_subscribers, { dismiss: true, tag: tag }, channel: :whisper)
  end

  def all_whisper_subscribers
    User.joins(:push_subs)
      .where(user_push_subscriptions: { channel: :whisper })
      .where.not(user_push_subscriptions: { registered_at: nil })
      .distinct
  end
end
