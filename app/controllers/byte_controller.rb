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
    @conversations = current_user.byte_conversations.active.ordered.to_a
    @conversation  = @conversations.first || ByteConversation.default_for(current_user)
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
    if body.start_with?("/") && (handled = handle_rails_slash_command(conversation, body))
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
    scope = scope.where("id < ?", before) if before && before > 0

    page = scope.chronological.last(limit)
    oldest_id = page.first&.id
    has_more  = oldest_id ? conversation.byte_messages.where("id < ?", oldest_id).exists? : false

    render json: {
      conversation_id: conversation.id,
      messages:        page.map(&:as_wire),
      has_more:        has_more,
      oldest_id:       oldest_id,
    }
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
    mode = normalized_mode(params[:mode])
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

  # Long-lived PWAs eventually outlive the CSRF token baked into the
  # initial shell.
  def csrf
    return head :forbidden unless current_user&.me?

    render json: { token: form_authenticity_token }
  end

  private

  def authorize_owner
    head :forbidden unless current_user&.me?
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
      new_mode = normalized_mode(arg)
      return ack(conversation, "usage: `/mode claude|bash|jarvis`") if arg.empty?
      conversation.update!(mode: new_mode)
      broadcast_convo_change(conversation, :updated)
      ack(conversation, "Mode set to **#{new_mode}** for this conversation.")
    end
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
    if conversation.jarvis?
      ByteJarvisWorker.perform_async(message.id)
      return
    end

    # Fire-and-forget to the local Mac server. If it fails, the message
    # sits in :pending / :failed — surfaced in the UI so the user can retry.
    Thread.new {
      begin
        response = ByteLocal.deliver(message, conversation: conversation)
        message.update!(state: response&.is_a?(Net::HTTPSuccess) ? :sent : :failed)
        broadcast(message.reload)
      rescue => e
        Rails.logger.warn("[Byte] deliver thread crashed: #{e.class}: #{e.message}")
        message.update!(state: :failed)
        broadcast(message.reload)
      end
    }
  end
end
