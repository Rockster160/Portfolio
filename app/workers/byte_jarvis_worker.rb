# Handles a single Byte message whose conversation mode is :jarvis.
# Sends the body through Jarvis and posts the response back as an inbound
# message on the same conversation.
#
# Jarvis mode intentionally skips the Mac local server — Jarvis lives
# entirely in Rails and doesn't need a shell / Claude CLI wrapper. Keeps
# the round-trip in-process, faster than a webhook bounce.
class ByteJarvisWorker
  include Sidekiq::Worker
  sidekiq_options queue: :default, retry: 3

  def perform(message_id)
    message = ByteMessage.find_by(id: message_id)
    return if message.nil?

    conversation = message.byte_conversation
    user         = message.user
    return if conversation.nil? || user.nil?

    # Mark the user's send as sent so the composer's pending state clears.
    message.update!(state: :sent) if message.state == "pending"

    body = message.body.to_s.strip
    return if body.empty?

    response = ::Jarvis.command(user, body)
    text     = response.is_a?(Array) ? response.first.to_s : response.to_s
    data     = response.is_a?(Array) ? (response.last || {}) : {}

    # If Jarvis emitted structured button data alongside its reply, render
    # an action-request bubble with tap targets instead of (or in addition
    # to) plain text. Format: `[reply_text, { byte_buttons: [...], multi_select: bool, title: "" }]`.
    button_list = (data.is_a?(Hash) ? (data["byte_buttons"] || data[:byte_buttons]) : nil)
    if button_list.is_a?(Array) && button_list.any?
      buttons  = button_list
      multi    = data["multi_select"] || data[:multi_select]
      title    = data["title"] || data[:title] || "Jarvis"
      subtitle = text.to_s.presence || "Choose an option"

      ByteAction.create_request!(
        user:         user,
        conversation: conversation,
        kind:         :jarvis,
        title:        title,
        subtitle:     subtitle,
        buttons:      buttons.map { |b| b.is_a?(Hash) ? b : { "label" => b.to_s, "value" => b.to_s } },
        multi_select: !!multi,
      )
      broadcast(user, message.reload)
      return
    end

    text = "(no response)" if text.strip.empty?

    reply = conversation.byte_messages.create!(
      user:         user,
      direction:    :inbound,
      state:        :delivered,
      body:         text,
      metadata:     { kind: :jarvis, in_reply_to: message.id },
      delivered_at: Time.current,
    )

    broadcast(user, message.reload)
    broadcast(user, reply)
  rescue => e
    Rails.logger.warn("[ByteJarvis] #{e.class}: #{e.message}")
    fail_body = "Jarvis error: #{e.class}: #{e.message}"
    conversation&.byte_messages&.create!(
      user:         user,
      direction:    :inbound,
      state:        :failed,
      body:         fail_body,
      metadata:     { kind: :system, error: true, in_reply_to: message&.id },
      delivered_at: Time.current,
    )&.then { |m| broadcast(user, m) }
  end

  private def broadcast(user, message)
    MonitorChannel.broadcast_to(user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: message.as_wire },
    })
  end
end
