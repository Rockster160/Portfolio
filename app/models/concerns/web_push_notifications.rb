# WebPushNotifications.send_to(User.me, { title: "Hello, World", body: "This is a message from Jarvis" })
# WebPushNotifications.send_to(User.me, { title: "Hello" }, channel: :whisper)
# WebPushNotifications.broadcast_to_channel([user1, user2], { title: "Hello" }, channel: :whisper)
# WebPushNotifications.send_to_whisper({ title: "Fed!" }) # sends to all whisper subscribers
# WebPushNotifications.send_to_whisper({ title: "Fed!", users: [user1] }) # sends to specific users
module WebPushNotifications
  module_function

  # Everything this app pushes is somebody waiting on it: a message from their
  # companion, a prompt, a reminder coming due, the cat wanting feeding. None
  # of it is background sync, and none of it is worth holding back.
  #
  # The gem's default is `Urgency: normal` and nothing overrode it. Every
  # endpoint here is `web.push.apple.com`, and a non-high urgency is an
  # explicit hint that the push may be held until the device next wakes on its
  # own — which is why a message can be written, broadcast, and sitting in the
  # thread for minutes before the phone buzzes about it. It is invisible from
  # this end: the send succeeded, immediately, long before anyone was told.
  #
  # The cost is battery, knowingly. A companion that answers you in a minute
  # and a half is not a companion.
  URGENCY = "high".freeze

  # The exception, and the only one: a dismissal has nobody waiting by
  # definition — it's tidying away a notification already dealt with.
  DISMISS_URGENCY = "low".freeze

  # A push service that accepts the connection and then never answers used to
  # hold the thread indefinitely, and these sends are SERIAL: one stuck device
  # delays every other device on the account behind it. Generous, but finite.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # Push to EVERY registered device on the channel, not just the newest one.
  #
  # It used to send to `primary_push_sub` alone — the most recently registered
  # subscription — which meant a person with a phone and a desktop PWA got their
  # notifications on exactly one of them, whichever they had most recently
  # opened. Opening Byte on the Mac silently took the phone off the list, and
  # relay messages ("Chelsea says…") stopped arriving on the device that
  # actually goes everywhere with them.
  #
  # `subscriptions:` narrows the fan-out. ByteNotifier uses it to drop the
  # device that's already looking at the thread while still reaching the others,
  # which is the whole point of presence: mute the screen you're reading, not
  # the phone in your pocket.
  def send_to(user, payload={}, channel: :jarvis, subscriptions: nil)
    return puts("\e[33m[WEBPUSH][#{user.username}] #{payload.inspect}\e[0m") if Rails.env.development?
    return "Failed to push - user not found" if user.blank?

    subs = (subscriptions || user.all_push_subs_for_channel(channel)).select(&:pushable?)
    # Every caller throws this return value away, so a channel with no usable
    # subscription goes silent and NOTHING says so. An expiry disables that
    # subscription below (registered_at: nil) and from then on it's a no-op
    # until the person happens to open the app and re-register - which reads,
    # from the outside, as notifications having simply stopped working. This is
    # the one line that makes that state findable in the log.
    if subs.empty?
      Rails.logger.warn("[WEBPUSH] dropped #{channel} push for #{user.username} - no registered subscription")
      return "Failed to push - push_sub not set up"
    end

    # example payload = {
    #   title: "Ardesian",
    #   body: "You have a new message!",
    #   count: 16,
    #   icon: "https://via.placeholder.com/100",
    #   url: "https://google.com"
    # }

    payload = payload.deep_symbolize_keys
    # A payload with no title is a SILENT push, and there are two kinds worth
    # sending: a dismissal, and a bare count.
    #
    # The count is how a badge gets cleared on a device that isn't running.
    # Reading a thread on the desk browser broadcasts over the socket, and a
    # phone in a pocket receives nothing at all — so its icon kept the number
    # for something already read, sometimes for days. `byte_worker.js` has
    # always handled this shape correctly: it calls `clearAppBadge` on a zero
    # and shows no banner without a title. Nothing ever reached it, because
    # this line dropped every count-only push before it was sent.
    return if payload[:title].blank? && !payload[:dismiss] && !payload.key?(:count) && payload[:data].blank?

    message = format_payload(user, payload, channel).to_json
    urgency = payload[:dismiss] ? DISMISS_URGENCY : URGENCY
    # One device failing must not cost the others their notification, so each
    # send is isolated. A dead subscription is retired on the spot.
    results = subs.map { |sub| deliver_push(user, sub, message, channel, urgency: urgency) }

    results.include?("Push success") ? "Push success" : results.first
  end

  def deliver_push(user, push_sub, message, channel, urgency: URGENCY)
    WebPush.payload_send(
      message:      message,
      endpoint:     push_sub.endpoint,
      p256dh:       push_sub.p256dh,
      auth:         push_sub.auth,
      urgency:      urgency,
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT,
      vapid:        {
        subject:     "mailto:rocco@ardesian.com",
        public_key:  ENV.fetch("PORTFOLIO_VAPID_PUB", nil),
        private_key: ENV.fetch("PORTFOLIO_VAPID_SEC", nil),
      },
    )
    "Push success"
  # A timeout says nothing about whether the subscription is still good, so it
  # is NOT retired — that's reserved for the push service telling us it's gone.
  # Left unrescued it would take the whole fan-out, and with it the turn that
  # was only trying to say a notification had been sent.
  # Net::OpenTimeout and Net::ReadTimeout are both Timeout::Error.
  rescue Timeout::Error => e
    Rails.logger.warn("[WEBPUSH] timed out for #{user.username} (#{channel}): #{e.class}")
    "Failed to push - timed out"
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription => e
    # Subscription is no longer valid (410 Gone or 404 Not Found)
    # Mark it as unregistered so we don't keep trying
    SlackNotifier.notify("[WEBPUSH] Subscription expired for #{user.username} (#{channel}): #{e.class}")
    push_sub.update(registered_at: nil)
    "Failed to push - subscription expired"
  rescue WebPush::Unauthorized => e
    SlackNotifier.notify("[WEBPUSH] Unauthorized for #{user.username} (#{channel}): #{e.message}")
    "Failed to push - (WebPush Error) [#{e.class}] #{e}"
  rescue WebPush::ResponseError => e
    SlackNotifier.notify("[WEBPUSH] Error for #{user.username} (#{channel}): [#{e.class}] #{e.message}")
    "Failed to push - (WebPush Error) [#{e.class}] #{e}"
  end

  def dismiss(user, tag, channel: :jarvis)
    send_to(user, { dismiss: true, tag: tag }, channel: channel)
  end

  def update_count(user, count=nil)
    send_to(user, { count: count || user_counts(user) })
  end

  def user_counts(user)
    user.prompts.unanswered.reload.count
  end

  def format_payload(user, payload, channel)
    extra_data = payload.deep_symbolize_keys!.slice!(*payload_keys)

    extra_data[:count] ||= user_counts(user) if channel.to_sym == :jarvis

    payload[:data] ||= {}
    payload[:data].merge!(extra_data)

    payload.compact_blank
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
      # Behavioral Options
      :tag, # <String>
      :data, # <Anything>
      :requireInteraction, # <boolean>
      :renotify, # <Boolean>
      :silent, # <Boolean>
      :dismiss, # <Boolean> - used to dismiss notifications by tag
      # Both Visual & Behavioral Options
      :actions, # <Array of Strings> or <[{ action: "", title: "", icon: "" }]>
      # Information Option. No visual effect.
      :timestamp, # <Long>
    ]
  end

  # Broadcast to multiple users on a specific channel
  def broadcast_to_channel(users, payload={}, channel:)
    subscriptions = payload.delete(:subscriptions)
    Array.wrap(users).map { |user|
      send_to(user, payload, channel: channel, subscriptions: subscriptions)
    }
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

  # Convenience method for Byte notifications — sends to all subscribers
  # by default; pass `users:` to scope down.
  def send_to_byte(payload={})
    payload = { title: payload } if payload.is_a?(::String)
    payload = payload.deep_symbolize_keys
    payload[:icon] ||= "/byte_favicon/byte-detail.png"
    payload[:data] ||= {}
    payload[:data][:url] ||= "/byte"

    users = payload.delete(:users) || all_byte_subscribers
    broadcast_to_channel(users, payload, channel: :byte)
  end

  def all_byte_subscribers
    User.joins(:push_subs)
      .where(user_push_subscriptions: { channel: :byte })
      .where.not(user_push_subscriptions: { registered_at: nil })
      .distinct
  end
end
