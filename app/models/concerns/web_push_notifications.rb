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

    formatted = format_payload(user, payload, channel)
    # Whatever the badge is being set to, it is now what the device believes —
    # which is what `push_badge` compares against to decide whether a clear is
    # worth a push of its own.
    record_badge(user, formatted.dig(:data, :count), channel: channel)

    message = formatted.to_json
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

  # Every subscription here is created with `userVisibleOnly: true`, which is a
  # promise that a push results in something the person can see. WebKit enforces
  # it: a worker that takes a push and shows no notification gets the whole
  # SUBSCRIPTION revoked, and the device comes back with a new endpoint.
  #
  # A badge-only push shows nothing by design, so a stream of them is a stream
  # of broken promises. That is what happened: from 2026-09-03, when a titleless
  # payload was first let through and a silent push went out on every READ,
  # endpoints stopped lasting weeks and started lasting minutes. A 845-day-old
  # Jarvis subscription died the same evening.
  #
  # So the count RIDES ALONG on notifications that show something — `send_to`
  # attaches it for Jarvis and ByteNotifier passes it for Byte — and the only
  # push spent on the badge alone is the fall to zero, once, on the edge. A
  # count that is still zero was already cleared; sending it again buys nothing
  # and costs the subscription.
  # `UserCache`, not `Rails.cache`: the number a device is currently wearing has
  # to be readable from whichever process handles the next read, and it has to
  # survive a restart. A badge that forgets itself is a badge that never clears.
  BADGE_CACHE_KEY = :push_badge

  def update_count(user, count=nil)
    push_badge(user, count || user_counts(user))
  end

  def push_badge(user, count, channel: :jarvis)
    return if user.blank?

    count    = count.to_i
    previous = user.caches.dig(BADGE_CACHE_KEY, channel.to_sym)
    # Recorded BEFORE the guards, so a second read landing at the same moment
    # sees zero and doesn't send a second copy of the same clear.
    record_badge(user, count, channel: channel)
    return if count.positive?
    # Unknown is not the same as non-zero. With nothing recorded there is no
    # edge to be on, and guessing means a silent push on every read again.
    return if previous.blank? || previous.to_i.zero?

    send_to(user, { count: 0 }, channel: channel)
  end

  def record_badge(user, count, channel: :jarvis)
    return if user.blank? || count.nil?

    user.caches.dig_set(BADGE_CACHE_KEY, channel.to_sym, count.to_i)
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
