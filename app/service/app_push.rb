# Native pushes to the phone app, alongside web push. WebPushNotifications.send_to
# hands every payload here first, so anything that already notifies (Byte,
# timers, agenda, chores, Jil) reaches the app without its caller knowing.
#
# Unlike web push, a native push may be silent: a badge-only count, or a
# background push telling the app to take a notification back off the screen.
module AppPush
  module_function

  ALERT_KEYS = [:title, :body].freeze
  # Notifications from these channels break through Focus, the way a ringing
  # timer should.
  TIME_SENSITIVE = [:timers].freeze

  def devices(user, channel=nil, feature: :push)
    return [] if user.blank?

    found = AppDevice.for_push(user, feature)
    channel ? found.select { |device| device.push_channel?(channel) } : found
  end

  def any_for?(user, channel)
    devices(user, channel).any?
  end

  # A person who has switched native push on and asked it to stand in for the
  # home-screen web app hears each thing once, not once per surface.
  def replaces_web_push?(user, channel)
    devices(user, channel).any? { |device| device.preference?(:native_push_replaces_web_push) }
  end

  def deliver(user, payload, channel: :jarvis)
    targets = devices(user, channel)
    return [] if targets.empty?

    payload = payload.to_h.deep_symbolize_keys
    data = payload[:data].to_h
    count = data.key?(:count) ? data[:count] : payload[:count]

    if payload[:title].blank? && payload[:body].blank?
      return quiet(targets, payload, count)
    end

    targets.map { |device|
      deliver_to(device, alert_payload(device, payload, channel: channel, count: count))
    }
  end

  # What a notification looks like to the app. Keys outside `aps` are read by
  # the app and its notification service extension.
  def alert_payload(device, payload, channel:, count: nil)
    data = payload[:data].to_h
    aps = {
      alert:             { title: payload[:title].presence, body: payload[:body].presence }.compact,
      sound:             sound_file(payload[:sound].presence || data[:sound].presence),
      "thread-id":       channel.to_s,
      "mutable-content": 1,
    }
    aps[:badge] = count.to_i if !count.nil? && device.preference?(:push_badges)
    aps[:"interruption-level"] = "time-sensitive" if TIME_SENSITIVE.include?(channel.to_sym)

    actions = Array(payload[:actions].presence || data[:actions])
    answer = payload[:answer] || data[:answer]
    if actions.any? && device.feature?(:actionable_notifications)
      aps[:category] = "buddy.dynamic"
    else
      actions = []
      # A Buddy message with nothing to ask gets the phone's own Reply and
      # Mark Read buttons.
      buttons = channel.to_sym == :byte && device.feature?(:actionable_notifications)
      aps[:category] = "buddy.reply" if buttons
    end

    {
      aps:             aps,
      tag:             payload[:tag],
      url:             payload[:url] || data[:url],
      channel:         channel.to_s,
      conversation_id: data[:conversation_id],
      image:           absolute(payload[:image]),
      actions:         actions.presence,
      answer:          (answer if actions.any?),
      button_actions:  ((payload[:button_actions] || data[:button_actions]) if actions.any?),
    }.compact
  end

  # Badge-only and dismissal pushes. Nothing is shown; the app is told what to
  # take away.
  def quiet(targets, payload, count)
    targets.flat_map { |device|
      sent = []
      if payload[:dismiss] && payload[:tag].present? && device.preference?(:push_badges)
        sent << deliver_to(device, background(remove_tags: [payload[:tag]]), push_type: :background)
      end
      if !count.nil? && device.preference?(:push_badges)
        # Not stored: Apple keeps one undelivered push per app, and a waiting
        # alert is worth more than a count the next push will carry anyway.
        sent << deliver_to(device, { aps: { badge: count.to_i } }, expiration: 0)
        sent << deliver_to(device, background(clear_all: true), push_type: :background) if count.to_i.zero?
      end
      sent
    }
  end

  # The unread count changed because something was READ, which a device in a
  # pocket only hears through a push.
  def badge(user, count)
    deliver(user, { data: { count: count } }, channel: :byte)
  end

  def conversation_read(user, conversation, count)
    targets = devices(user, :byte)
    targets.each { |device|
      if device.preference?(:push_badges)
        deliver_to(device, background(remove_conversation: conversation.id), push_type: :background)
      end
    }
    quiet(targets, {}, count)
  rescue StandardError => e
    Rails.logger.warn("[APP_PUSH] read for #{user&.username}: #{e.class}: #{e.message}")
  end

  # A sound the app bundles (App/Resources/Sounds), or the system's own.
  def sound_file(name)
    name.present? ? "#{name}.caf" : "default"
  end

  def background(extra)
    { aps: { "content-available": 1 } }.merge(extra)
  end

  def deliver_to(device, payload, push_type: :alert, expiration: nil)
    result = Apns.deliver(
      token:       device.apns_token,
      payload:     payload,
      environment: device.apns_environment,
      push_type:   push_type,
      expiration:  expiration,
    )
    device.update(apns_token: nil) if result.dead_token?
    result
  rescue StandardError => e
    Rails.logger.warn("[APP_PUSH] #{device.id}: #{e.class}: #{e.message}")
    nil
  end

  # Widgets on the phone ask again. Coalesced per person: a list edited ten
  # times in a second reloads its widget once, a few seconds later.
  def reload_widgets_later(users)
    Array(users).compact.each { |user|
      next if AppDevice.active.where(user_id: user.id).where.not(widget_push_token: [nil, ""]).none?

      key = "app_push:widgets:#{user.id}"
      next unless Rails.cache.write(key, true, expires_in: 5.seconds, unless_exist: true)

      AppWidgetReloadWorker.perform_in(5.seconds, user.id)
    }
  end

  def reload_widgets(user)
    AppDevice.active.where(user_id: user.id).where.not(widget_push_token: [nil, ""]).map { |device|
      next unless device.feature?(:widgets)

      result = Apns.deliver(
        token:        device.widget_push_token,
        payload:      { aps: { "content-changed": true } },
        environment:  device.apns_environment,
        push_type:    :widgets,
        topic_suffix: "push-type.widgets",
      )
      device.update(widget_push_token: nil) if result.dead_token?
      result
    }.compact
  end

  def absolute(url)
    return if url.blank?
    return url if url.to_s.match?(%r{\Ahttps?://})

    host = Rails.application.routes.default_url_options[:host] || "ardesian.com"
    "https://#{host}#{"/" unless url.to_s.start_with?("/")}#{url}"
  end
end
