# Push notifications for Byte messages, extracted from
# WebhooksController#byte_notify so both delivery paths share one
# implementation: the Mac webhook (claude / bash / system replies) and the
# in-Rails Buddy turn (Buddy::GPT::Turn), which never touches the webhook.
#
# Only fires on terminal states — silent while streaming. Every kind gets a
# push UNLESS the user's PWA is currently foreground (server-side presence
# heartbeat via ByteController#presence). Presence is checked server-side so we
# never hand a push to iOS to potentially fall-back-render; SW-side suppression
# can't beat iOS's `userVisibleOnly` enforcement.
module ByteNotifier
  module_function

  PREVIEW_LIMIT = 160

  def notify(user, message)
    return unless message.state == "delivered"

    meta = message.metadata.is_a?(Hash) ? message.metadata : {}

    # Buddy replies carrying a proposal checklist are a WAITING ASK — the user
    # must tap boxes for anything to happen.
    has_proposals = meta["tool_name"] == "buddy_proposals" ||
      (meta["buttons"].is_a?(Array) && meta["buttons"].any?)

    return if device_present?(user) && !always_notify?(meta, has_proposals)

    title, body = framing(message, meta, has_proposals)

    WebPushNotifications.send_to_byte(
      title: title,
      body:  body,
      tag:   "byte-#{message.id}",
      users: [user],
    )
  end

  # Presence suppression assumes "the app is open" means "they'll see it". That
  # holds for ordinary back-and-forth and fails for everything below, where the
  # PWA may be present-but-backgrounded on a lock screen, or the heartbeat may
  # simply be stale.
  def always_notify?(meta, has_proposals)
    return true if has_proposals            # a checklist waiting on their tap
    return true if meta["kind"] == "action-request"

    # Buddy speaking on its own initiative: a reminder firing, a watch tripping,
    # the morning briefing. They didn't ask for it and aren't waiting on it, so
    # whether the app happens to be open says nothing about whether they'll see
    # it — and a reminder that arrives silently is the whole feature failing.
    # CompanionDelivery#deliver_plain already ignores presence for exactly this
    # reason; the prompt path routes through a Buddy turn and used to lose it.
    meta["self_initiated"] == true
  end

  # Is the device we're about to push to looking at Byte right now? Populated
  # by the `/byte/presence` heartbeat while that device's window is visible.
  #
  # The question has to be about ONE device — the one `send_to` would deliver
  # to — because that's the only screen this notification would land on.
  # Suppressing on "any Byte anywhere is open" meant a browser tab at the desk
  # muted the phone, and a CLI message answered from that desk arrived on the
  # phone silently every time.
  def device_present?(user)
    sub = user.primary_push_sub(channel: :byte)
    return false if sub.nil?

    Rails.cache.read(ByteController.presence_key(user, sub)).present?
  end

  # Push tray shows plain text — strip everything that would look like garbage:
  # HTML tags (shell bubbles carry ANSI-styled <span>s), fenced/inline markdown
  # code, bold/italic delimiters, ANSI escapes (if any leaked), blockquote
  # markers, and any residual whitespace.
  def clean_body(raw)
    text = raw.to_s
    text = text.gsub(/```[a-z]*\n?/i, "").gsub(/```/, "")            # fenced code delimiters
    text = text.gsub(/`([^`]+)`/, '\1')                              # inline code
    text = text.gsub(/\*\*([^*]+)\*\*/, '\1')                        # bold
    text = text.gsub(/(?<!\*)\*(?!\*)([^*]+)(?<!\*)\*(?!\*)/, '\1')  # italic
    text = text.gsub(/<[^>]+>/, "")                                  # HTML tags (from shell)
    text = text.gsub(/\e\[[0-9;?=<>]*[a-zA-Z]/, "")                  # ANSI escapes
    text = text.gsub(/^>\s?/, "")                                    # blockquote
    text.gsub(/\s+/, " ").strip
  end

  # The OS already stamps the app name (Byte) on the notification, so the TITLE
  # is the message itself — not the thread name. Any actionable framing (a
  # confirm cue, an approval prompt) rides in the body.
  def framing(message, meta, has_proposals)
    preview = clean_body(message.body).truncate(PREVIEW_LIMIT).presence

    if has_proposals
      # Count pending buttons so we don't under-sell a "5 things to confirm".
      n_pending = Array(meta["buttons"]).count { |b| (b["status"] || "pending") == "pending" }
      cue = n_pending > 1 ? "☐ #{n_pending} to confirm" : "☐ Tap to confirm"
      [preview || cue, (preview ? cue : nil)]
    elsif meta["kind"] == "action-request"
      action_request_framing(meta, preview)
    else
      [preview || "(attachment)", nil]
    end
  end

  def action_request_framing(meta, preview)
    tool = meta["tool_name"].to_s
    sub  = meta["subtitle"].to_s.presence
    cue  = case meta["action_kind"]
    when "plan"     then "📋 Plan approval"
    when "question" then "❓ Question"
    else                 "⚡ Approve #{tool}"
    end

    if preview
      [preview, [cue, sub].compact.join(" · ")]
    else
      [sub || cue, (sub ? cue : nil)]
    end
  end
end
