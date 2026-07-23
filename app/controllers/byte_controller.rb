class ByteController < ApplicationController
  before_action :authorize_user
  before_action :authorize_owner

  MONITOR_CHANNEL = :byte
  HISTORY_LIMIT = 100

  def show
    @messages = current_user.byte_messages.chronological.last(HISTORY_LIMIT)
  end

  def create_message
    body = params[:body].to_s.strip
    return head(:bad_request) if body.empty?

    message = current_user.byte_messages.create!(
      direction: :outbound,
      state:     :pending,
      body:      body,
      metadata:  { source: params[:source].to_s.presence || "web" },
    )

    broadcast(message)

    # Fire-and-forget to the local Mac server. If it fails, the message
    # sits in :pending — surfaced in the UI so the user can retry later.
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

  def messages
    @messages = current_user.byte_messages.chronological.last(HISTORY_LIMIT)
    render json: { messages: @messages.map(&:as_wire) }
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
