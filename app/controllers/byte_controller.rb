class ByteController < ApplicationController
  before_action :authorize_user, except: [:csrf]
  before_action :authorize_owner, except: [:csrf]

  MONITOR_CHANNEL = :byte
  # Page size for both the initial render and paginated back-scroll.
  # Matches the client's localStorage cap so a cold-open fetch fills it
  # exactly. `?limit=` can override up to MAX_LIMIT for larger bootstraps.
  HISTORY_LIMIT = 50
  MAX_LIMIT     = 200

  def show
    scope = current_user.byte_conversations.active.ordered
    scope = scope.buddy if buddy_only?
    @conversations = scope.to_a
    @conversation  = @conversations.first || default_conversation
    @messages      = @conversation.byte_messages.chronological.last(HISTORY_LIMIT)
  end

  def create_message
    body = params[:body].to_s.strip
    return head(:bad_request) if body.empty?

    conversation = resolve_conversation
    return head(:not_found) if conversation.nil?

    # Slash commands that mutate the *conversation itself* (rename, archive)
    # never leave Rails — no user outbound bubble is created, and the
    # response is a system-kind inbound acknowledgement. Everything else
    # (/sessions, /switch, /adopt, /watch, /pwd, ...) falls through to
    # the Mac via the normal message pipeline.
    # Accept either "/" or "." as the slash-command prefix. Both feel
    # natural on mobile (period is closer to the space bar than slash);
    # the dispatcher strips whichever one was used.
    if (body.start_with?("/") || body.start_with?(".")) && (handled = handle_rails_slash_command(conversation, body))
      return render(json: handled.as_wire, status: :ok)
    end

    metadata = {
      source: params[:source].to_s.presence || "web",
    }
    # `local_id` (UUID minted by the client before the outbound queue
    # entry was written) travels round-trip so the client can upgrade
    # its queued bubble to the server-assigned id after this response
    # instead of leaving a duplicate.
    local_id = params[:local_id].to_s.presence
    metadata[:local_id] = local_id if local_id

    incoming_meta = (params[:metadata] || {}).to_unsafe_h rescue {}
    metadata.merge!(incoming_meta.symbolize_keys.except(:source, :local_id))

    # Prefer the client-typed timestamp for `created_at` so a burst of
    # rapid sends stays in the user's typing order even when the network
    # delivers them to the server out of order. Fallback to Time.current
    # for callers that don't send one (or garbage).
    created = client_ts_from(params[:client_ts]) || Time.current

    # Brain-dump capture: if the person armed a "Stash" bucket, THIS message is
    # the idea being dumped — file it instead of running a normal Buddy turn.
    # The message still shows as their bubble; capture! adds the confirmation.
    if conversation.buddy? && (stash_category = ::Buddy::Stash.armed_category(conversation))
      message = conversation.byte_messages.create!(
        user:       current_user,
        direction:  :outbound,
        state:      :sent,
        body:       body,
        metadata:   metadata,
        created_at: created,
      )
      broadcast(message)
      ::Buddy::Stash.capture!(current_user, conversation, message, stash_category)
      return render(json: message.as_wire, status: :created)
    end

    message = conversation.byte_messages.create!(
      user:       current_user,
      direction:  :outbound,
      state:      :pending,
      body:       body,
      metadata:   metadata,
      created_at: created,
    )

    broadcast(message)
    dispatch_message(conversation, message)

    render json: message.as_wire, status: :created
  end

  # Paginated history.
  #   (no params)               → latest HISTORY_LIMIT messages (chronological)
  #   ?conversation_id=<n>      → filter to a single conversation (default: primary)
  #   ?before=<id>              → previous HISTORY_LIMIT messages older than <id>
  #   ?limit=<n>                → override page size, capped at MAX_LIMIT
  def messages
    conversation = resolve_conversation(missing_ok: true)
    return render(json: { messages: [], has_more: false }) if conversation.nil?

    before = params[:before].to_i if params[:before].present?
    limit  = params[:limit].to_i
    limit  = HISTORY_LIMIT if limit <= 0
    limit  = [limit, MAX_LIMIT].min

    scope = conversation.byte_messages
    scope = scope.where(id: ...before) if before&.positive?

    page = scope.chronological.last(limit)
    oldest_id = page.first&.id
    has_more  = oldest_id ? conversation.byte_messages.exists?(["id < ?", oldest_id]) : false

    render json: {
      conversation_id: conversation.id,
      messages:        page.map(&:as_wire),
      has_more:        has_more,
      oldest_id:       oldest_id,
    }
  end

  # Cancel a message the user queued while Buddy was asleep, before it
  # drains. Only :queued messages are cancellable — anything already
  # dispatched (sent/delivered) is out of the user's hands.
  def delete_message
    message = current_user.byte_messages.find_by(id: params[:id])
    return head(:not_found) if message.nil?
    return head(:unprocessable_entity) unless message.queued?

    conversation_id = message.byte_conversation_id
    message.destroy!
    MonitorChannel.broadcast_to(current_user, {
      id:      MONITOR_CHANNEL,
      channel: MONITOR_CHANNEL,
      data:    { kind: :message_deleted, message_id: params[:id].to_i, byte_conversation_id: conversation_id },
    })
    head :no_content
  end

  # ---------- conversation management ----------

  def list_conversations
    convos = current_user.byte_conversations.active.ordered
    render json: {
      conversations: convos.map(&:as_wire),
      default_id:    (convos.first || ByteConversation.default_for(current_user)).id,
    }
  end

  def create_conversation
    # Buddy-only members can never spin up a claude/bash/jarvis thread.
    mode = buddy_only? ? :buddy : normalized_mode(params[:mode])
    name = params[:name].to_s.strip.presence

    convo = current_user.byte_conversations.create!(
      name:            name,
      mode:            mode,
      last_message_at: Time.current,
    )
    broadcast_convo_change(convo, :created)
    render json: convo.as_wire, status: :created
  end

  def update_conversation
    convo = current_user.byte_conversations.find_by(id: params[:id])
    return head(:not_found) if convo.nil?

    attrs = {}
    attrs[:name]     = params[:name].to_s.strip.presence if params.key?(:name)
    attrs[:archived] = ActiveModel::Type::Boolean.new.cast(params[:archived]) if params.key?(:archived)
    if params.key?(:mode)
      new_mode = normalized_mode(params[:mode])
      attrs[:mode] = new_mode if new_mode
    end
    # Metadata merges (never replaces) so other writers' fields survive —
    # e.g. bash cwd stays put when Claude session id is stashed.
    if params.key?(:metadata)
      incoming = (params[:metadata].to_unsafe_h rescue {}).stringify_keys
      attrs[:metadata] = (convo.metadata || {}).merge(incoming)
    end
    convo.update!(attrs) if attrs.any?

    broadcast_convo_change(convo, :updated)
    render json: convo.as_wire
  end

  def archive_conversation
    convo = current_user.byte_conversations.find_by(id: params[:id])
    return head(:not_found) if convo.nil?

    convo.update!(archived: true)
    broadcast_convo_change(convo, :archived)
    head :no_content
  end

  # List the Mac's Claude Code sessions for the current conversation's cwd.
  # Powers the "adopt existing session" picker so the user can wire a Byte
  # conversation to an already-running session by name.
  def claude_sessions
    return head(:not_found) unless ByteLocal.respond_to?(:list_claude_sessions)

    convo = resolve_conversation
    return head(:not_found) if convo.nil?

    result = ByteLocal.list_claude_sessions(conversation_id: convo.id)
    render json: { sessions: result || [] }
  end

  # PWA button tap → records the decision on ByteAction, updates the
  # message state, broadcasts the update, and pings the Mac's decision
  # hook so any waiting Claude Code PreToolUse hook wakes up.
  def respond_action
    action = current_user.byte_actions.find_by(request_id: params[:request_id])
    return head(:not_found) if action.nil?

    # Buddy proposal checklists are incremental: each checkbox tap executes
    # that one proposal and leaves the rest live, so the action stays pending
    # across taps instead of being a single all-or-nothing decision. Its own
    # path below; the standard apply_decision! flow (decide once -> decided,
    # cancel the unchecked) is the wrong shape for it.
    return respond_buddy_proposals(action) if action.tool_name == "buddy_proposals"

    # A relayed cross-user question. The tapped option(s) are the recipient's
    # answer; record it and hand it back to the asker's companion.
    return respond_buddy_relay(action) if action.tool_name == "buddy_relay_answer"

    # The reminders management list: tapping × cancels a row's reminder/watch,
    # Undo restores it. Not a decision-recording flow — its own tiny path.
    return respond_buddy_reminders(action) if action.tool_name == Buddy::ReminderList::TOOL_NAME

    return head(:conflict) unless action.pending?

    value = params[:value]
    if action.multi_select
      value = Array(value).map(&:to_s)
    end

    action.apply_decision!(value: value, source: :user)

    if action.byte_message
      MonitorChannel.broadcast_to(current_user, {
        id:      MONITOR_CHANNEL,
        channel: MONITOR_CHANNEL,
        data:    { kind: :message, message: action.byte_message.reload.as_wire },
      })
    end

    # Buddy's checkbox actions are grouped proposals; hand off to the
    # executor which runs each checked tool and posts a receipt bubble.
    if action.tool_name == "buddy_proposals"
      Buddy::ProposalExecutorJob.perform_later(action.id)
    end

    # Fire-and-forget notification to the Mac so a blocked hook can
    # unblock. Silent on failure — the hook will time out and deny.
    # Executor.wrap ensures the checked-out AR connection is released
    # even if the HTTP call to Mac hangs.
    Thread.new {
      Rails.application.executor.wrap do
        ByteLocal.notify_action_decision(action)
      rescue StandardError => e
        Rails.logger.warn("[Byte] action decision notify failed: #{e.class}: #{e.message}")
      end
    }

    # For Jarvis-mode clarifications, the tap ALSO fires the chosen
    # value as a fresh Jarvis command in the same conversation.
    if action.jarvis?
      chosen = Array(value).first.to_s
      if chosen.present?
        followup = action.byte_conversation.byte_messages.create!(
          user:      current_user,
          direction: :outbound,
          state:     :sent,
          body:      chosen,
          metadata:  { source: :button, action_request_id: action.request_id },
        )
        broadcast(followup)
        ByteJarvisWorker.perform_async(followup.id)
      end
    end

    render json: action.as_wire
  end

  # Incremental checkbox tap on a Buddy proposal checklist. `value` is the id
  # (or ids) the user just checked; the executor runs those and leaves every
  # other row pending. No Mac decision-notify (no blocked hook waits on these)
  # and no destructive apply_decision! — the action stays live until all rows
  # are resolved or it expires. Repeat/overlapping taps are idempotent.
  def respond_buddy_proposals(action)
    # Uncheck-to-undo on a Level-2 (already-executed) row. Allowed even once the
    # action is decided — undoing a done row isn't gated on pending state.
    if params[:undo].present?
      Buddy::ProposalExecutor.undo!(action.id, params[:undo].to_i)
      return render json: action.reload.as_wire
    end

    # Tapping an EXPIRED row: reissue it as a fresh checklist so the person
    # doesn't have to re-type the request. Allowed regardless of expiry (that's
    # the whole point).
    if params[:redo].present?
      btn = Array(action.buttons).find { |b| b["id"].to_i == params[:redo].to_i }
      Buddy::ProposalBuilder.reissue(user: current_user, conversation: action.byte_conversation, button: btn) if btn
      return render json: action.as_wire
    end

    return head(:conflict) unless action.pending? &&
      (action.expires_at.nil? || action.expires_at.future?)

    ids = Array(params[:value]).map(&:to_i).reject(&:zero?)
    Buddy::ProposalExecutorJob.perform_later(action.id, ids) if ids.any?

    render json: action.as_wire
  end

  # A tap on the reminders management list. `cancel` takes a row off (cancels
  # its reminder/watch), `undo` restores one. Row lookups + record edits happen
  # in Buddy::ReminderList, which re-broadcasts the updated list.
  def respond_buddy_reminders(action)
    if params[:undo].present?
      Buddy::ReminderList.restore!(action, params[:undo].to_i)
    elsif params[:cancel].present?
      Buddy::ReminderList.cancel!(action, params[:cancel].to_i)
    end

    render json: action.reload.as_wire
  end

  # The recipient tapped an answer on a relayed cross-user question. Map the
  # checked option(s) to the answer, record it, and relay it back to whoever
  # asked. Idempotent: a question already answered just re-renders.
  def respond_buddy_relay(action)
    return head(:conflict) unless action.pending? &&
      (action.expires_at.nil? || action.expires_at.future?)

    ids = Array(params[:value]).map(&:to_i).reject(&:zero?)
    Buddy::CompanionRelay.answer_from_action(action, ids) if ids.any?

    render json: action.as_wire
  end

  # Heartbeat from the client while the PWA is foreground. Records a
  # short-lived "user is looking at Byte right now" fact in Rails.cache.
  # `byte_notify` (webhooks_controller.rb) consults this to skip pushing
  # a system-level notification for a message the user is about to see
  # in-app via the WebSocket broadcast anyway.
  #
  # Client pings on visibilitychange → visible, and on a 15s interval
  # while it stays visible. TTL is 30s so a missed heartbeat still
  # falls off within one interval.
  def presence
    return head(:forbidden) unless current_user&.me?

    state = params[:state].to_s
    if state == "visible"
      Rails.cache.write(presence_key(current_user), Time.current.to_i, expires_in: 30.seconds)
    elsif state == "hidden"
      Rails.cache.delete(presence_key(current_user))
    end
    head :no_content
  end

  def self.presence_key(user)
    "byte:presence:#{user.id}"
  end

  def presence_key(user)
    self.class.presence_key(user)
  end

  # Long-lived PWAs eventually outlive the CSRF token baked into the
  # initial shell.
  def csrf
    return head :forbidden unless byte_accessible?

    render json: { token: form_authenticity_token }
  end

  private

  def authorize_owner
    head :forbidden unless byte_accessible?
  end

  # Who may open Byte at all: the owner (Rocco) and Chelsea. No one else —
  # the page dispatches Bash/Claude to the owner's Mac, so it is
  # deliberately not a general-user surface.
  def byte_accessible?
    current_user&.me? || current_user&.chelsea?
  end

  # Non-owner household members get Buddy ONLY. claude/bash/jarvis modes
  # hand off to the owner's Mac, so they stay owner-exclusive; everyone
  # else is pinned to :buddy for both new conversations and dispatch.
  def buddy_only?
    !current_user&.me?
  end

  # First-open conversation. Owners get the normal claude default; buddy-only
  # members get a Buddy conversation so the page has something to show.
  def default_conversation
    if buddy_only?
      current_user.byte_conversations.create!(mode: :buddy)
    else
      ByteConversation.default_for(current_user)
    end
  end

  # Resolve the target conversation for this request. Falls back to the
  # user's default (creating one if absent) when no id is passed — that
  # keeps legacy clients working while migration is in flight.
  def resolve_conversation(missing_ok: false)
    id = params[:conversation_id].presence
    if id.present?
      convo = current_user.byte_conversations.find_by(id: id)
      return nil if convo.nil? && missing_ok
      return convo if convo
    end

    ByteConversation.default_for(current_user)
  end

  def normalized_mode(raw)
    sym = raw.to_s.downcase.to_sym
    ByteConversation.modes.key?(sym.to_s) ? sym : :claude
  end

  # Client sends `client_ts` as JS `Date.now()` — a millisecond epoch.
  def client_ts_from(raw)
    ts = raw.to_i
    return nil if ts <= 0

    seconds = ts / 1000.0
    parsed = Time.zone.at(seconds) rescue nil
    return nil if parsed.nil?
    return nil if parsed < 1.day.ago || parsed > 1.day.from_now

    parsed
  end

  def broadcast(message)
    MonitorChannel.broadcast_to(current_user, {
      id:      MONITOR_CHANNEL,
      channel: MONITOR_CHANNEL,
      data:    { kind: :message, message: message.as_wire },
    })
  end

  def broadcast_convo_change(convo, kind)
    MonitorChannel.broadcast_to(current_user, {
      id:      MONITOR_CHANNEL,
      channel: MONITOR_CHANNEL,
      data:    { kind: :conversation, event: kind, conversation: convo.as_wire },
    })
  end

  # Slash commands whose scope is the Byte conversation record itself.
  # Returns a persisted acknowledgement message (system kind, inbound) or
  # nil if the command isn't ours to handle — caller falls through to the
  # normal Mac pipeline.
  def handle_rails_slash_command(conversation, body)
    verb, arg = body[1..].to_s.strip.split(/\s+/, 2)
    verb = verb.to_s.downcase
    arg  = arg.to_s.strip

    case verb
    when "rename"
      return ack(conversation, "usage: `/rename NEW NAME`") if arg.empty?

      old_name = conversation.display_name
      conversation.update!(name: arg)
      broadcast_convo_change(conversation, :updated)
      ack(conversation, "Renamed **#{old_name}** → **#{arg}**")
    when "archive"
      conversation.update!(archived: true)
      broadcast_convo_change(conversation, :archived)
      ack(conversation, "Archived **#{conversation.display_name}**")
    when "mode"
      return ack(conversation, "Buddy is the only mode available to you.") if buddy_only?

      new_mode = normalized_mode(arg)
      return ack(conversation, "usage: `/mode claude|bash|jarvis|buddy`") if arg.empty?

      conversation.update!(mode: new_mode)
      broadcast_convo_change(conversation, :updated)
      ack(conversation, "Mode set to **#{new_mode}** for this conversation.")
    when "fork", "continue"
      # Spin up a brand-new conversation with the same mode + same cwd.
      # Useful when the old shell died and left corrupt state, or the
      # Claude session hit a dead end and the user wants a clean slate
      # in the same directory.
      fork_conversation(conversation, arg.presence)
    end
  end

  def fork_conversation(source, custom_name)
    cwd = source.metadata.is_a?(Hash) ? source.metadata["cwd"] : nil
    new_name = custom_name.presence || "#{source.display_name} (continued)"

    forked = current_user.byte_conversations.create!(
      name:            new_name,
      mode:            source.mode,
      metadata:        cwd ? { cwd: cwd, forked_from: source.id } : { forked_from: source.id },
      last_message_at: Time.current,
    )
    broadcast_convo_change(forked, :created)

    body = "Forked → **#{forked.display_name}** (mode: #{forked.mode}#{", cwd: #{cwd}" if cwd})"
    ack(source, body)
  end

  # Persist + broadcast a system-kind acknowledgement bubble that stays
  # in the same conversation. Used for every Rails-owned slash reply.
  def ack(conversation, body)
    message = conversation.byte_messages.create!(
      user:         current_user,
      direction:    :inbound,
      state:        :delivered,
      body:         body,
      metadata:     { kind: :system, source: :slash },
      delivered_at: Time.current,
    )
    broadcast(message)
    message
  end

  # Route the outbound message according to its conversation's mode:
  # * jarvis → in-process worker; skips the Mac entirely
  # * claude / bash → hand off to the Mac via ByteLocal
  def dispatch_message(conversation, message)
    # Safety net: a buddy-only member must never reach the owner's Mac via a
    # claude/bash/jarvis conversation. Creation + /mode are already locked,
    # so this only fires on an unexpected legacy state — refuse the handoff.
    return if buddy_only? && !conversation.buddy?

    if conversation.jarvis?
      ByteJarvisWorker.perform_async(message.id)
      return
    end

    # If Buddy is currently asleep (Anthropic usage cap), HOLD the message
    # in the queue rather than dispatching or bouncing a canned reply. The
    # persistent sleeping chip on the client communicates the state, and
    # BuddyWakeWorker drains these in order when the wake window passes.
    # Only applies to :buddy mode; claude / bash still dispatch as normal.
    if conversation.buddy? && ::Buddy::SleepGuard.sleeping?(current_user)
      message.update!(state: :queued)
      broadcast(message.reload)
      return
    end

    # Auto-wake if the sleep window has passed.
    ::Buddy::SleepGuard.maybe_wake!(current_user) if conversation.buddy?

    # Flip the pet to `thinking` the moment a message is sent so there's
    # always visible life on a normal turn (quick-action chips already do
    # this). The reply resolves it back to a mood / neutral on arrival.
    ::Buddy::ExpressionState.transition!(conversation, :turn_started) if conversation.buddy?

    # Hand the Mac round-trip to Sidekiq. It used to run inline in a bare
    # Thread.new wrapped in executor.wrap, which held one of the web-sized
    # AR connections for the ENTIRE 5-30s Mac HTTP round-trip and starved
    # the pool — unrelated web requests hit ConnectionTimeoutError. The
    # worker routes :buddy through TurnDispatcher.deliver! (compaction,
    # state, broadcast, sleep-on-failure) and claude/bash to a plain handoff.
    BuddyDeliverWorker.perform_async(message.id)
  end
end
