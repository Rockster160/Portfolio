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
    # Server-render bootstrap holds a single page so the first paint is
    # instant. Older history hydrates via ?before= as the user scrolls.
    @messages = current_user.byte_messages.chronological.last(HISTORY_LIMIT)
  end

  def create_message
    body = params[:body].to_s.strip
    return head(:bad_request) if body.empty?

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

    message = current_user.byte_messages.create!(
      direction: :outbound,
      state:     :pending,
      body:      body,
      metadata:  metadata,
    )

    broadcast(message)

    # Fire-and-forget to the local Mac server. If it fails, the message
    # sits in :pending / :failed — surfaced in the UI so the user can retry.
    Thread.new {
      begin
        response = ByteLocal.deliver(message)
        message.update!(state: response&.is_a?(Net::HTTPSuccess) ? :sent : :failed)
        broadcast(message.reload)
      rescue => e
        Rails.logger.warn("[Byte] deliver thread crashed: #{e.class}: #{e.message}")
        message.update!(state: :failed)
        broadcast(message.reload)
      end
    }

    render json: message.as_wire, status: :created
  end

  # Paginated history.
  #   (no params)   → latest HISTORY_LIMIT messages (chronological)
  #   ?before=<id>  → previous HISTORY_LIMIT messages older than <id>
  #   ?limit=<n>    → override page size, capped at MAX_LIMIT
  #
  # Response also carries `has_more` so the client stops requesting
  # once it hits the head of the archive.
  def messages
    before = params[:before].to_i if params[:before].present?
    limit  = params[:limit].to_i
    limit  = HISTORY_LIMIT if limit <= 0
    limit  = [limit, MAX_LIMIT].min

    scope = current_user.byte_messages
    scope = scope.where("id < ?", before) if before && before > 0

    page = scope.chronological.last(limit)
    oldest_id = page.first&.id
    has_more  = oldest_id ? current_user.byte_messages.where("id < ?", oldest_id).exists? : false

    render json: {
      messages:  page.map(&:as_wire),
      has_more:  has_more,
      oldest_id: oldest_id,
    }
  end

  # Long-lived PWAs eventually outlive the CSRF token baked into the
  # initial shell. The client hits this endpoint on a 401/422 (or
  # proactively before draining a stale queue) to swap for a fresh token
  # without a full page reload.
  def csrf
    return head :forbidden unless current_user&.me?

    render json: { token: form_authenticity_token }
  end

  private

  def authorize_owner
    head :forbidden unless current_user&.me?
  end

  def broadcast(message)
    MonitorChannel.broadcast_to(current_user, {
      id:      MONITOR_CHANNEL,
      channel: MONITOR_CHANNEL,
      data:    { kind: :message, message: message.as_wire },
    })
  end
end
