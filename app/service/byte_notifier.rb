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
    return if kiosk?(message)

    meta = message.metadata.is_a?(Hash) ? message.metadata : {}

    # Buddy replies carrying a proposal checklist are a WAITING ASK — the user
    # must tap boxes for anything to happen.
    has_proposals = meta["tool_name"] == "buddy_proposals" ||
      (meta["buttons"].is_a?(Array) && meta["buttons"].any?)

    # Presence mutes the SCREEN THEY'RE READING, not the person.
    #
    # It used to be a single yes/no for the whole account, checked against the
    # newest-registered subscription — so a Byte tab open on the Mac suppressed
    # the push outright and the phone in their pocket got nothing. Every device
    # is offered the notification now; only the ones actually looking at Byte
    # right now are dropped.
    subs    = push_subs(user)
    targets = always_notify?(meta, has_proposals) ? subs : absent_subs(user)
    # Bail only when there WERE devices and every one of them is already
    # looking. With no subscriptions at all we carry on, so `send_to` logs the
    # "no registered subscription" warning — the one line that makes a silently
    # unregistered device findable.
    return if subs.any? && targets.empty?

    title, body = framing(message, meta, has_proposals)

    WebPushNotifications.send_to_byte(
      title:         title,
      body:          body,
      tag:           "byte-#{message.id}",
      users:         [user],
      subscriptions: targets,
      # The iOS home-screen badge. `byte_worker.js` has always read
      # `data.count` and called `setAppBadge`; nothing ever sent it, so the
      # number on the app icon was permanently absent. It has to ride the PUSH
      # because that's the only thing that runs while the app is closed, which
      # is exactly when a badge is the whole point.
      data:          { count: ByteConversation.unread_total_for(user) },
    )
  end

  # The wall tablet never pushes, and no exception in `always_notify?` gets to
  # override it. It's a screen that is always on and always in one room: it
  # renders everything live over the socket, so a push adds nothing THERE, and
  # what it would actually do is buzz the phone in somebody's pocket every time
  # a person standing in the kitchen taps a routine.
  #
  # A pinned thread is the whole test. There's no device-level way to ask this:
  # a push goes to every subscription on the account, and the tablet's browser
  # isn't a subscription anyone registered.
  def kiosk?(message)
    message.byte_conversation&.kiosk?
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

  def push_subs(user)
    user.all_push_subs_for_channel(:byte).to_a
  end

  # The devices NOT looking at Byte right now. Presence is populated per device
  # by the `/byte/presence` heartbeat while that device's window is visible.
  #
  # Per device, and per device only. "Any Byte anywhere is open" meant a browser
  # tab at the desk muted the phone; checking just the newest-registered
  # subscription had the same effect for a different reason, because that one
  # subscription was also the only one `send_to` ever delivered to.
  def absent_subs(user)
    push_subs(user).reject { |sub| Rails.cache.read(ByteController.presence_key(user, sub)).present? }
  end

  # Kept for callers and specs that ask the old yes/no question: is the person
  # looking at Byte on the device this would have gone to?
  def device_present?(user)
    subs = push_subs(user)
    subs.any? && absent_subs(user).empty?
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
