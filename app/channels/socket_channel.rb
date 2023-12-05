class SocketChannel < ApplicationCable::Channel
  def self.send_to(user, channel, data)
    SocketChannel.broadcast_to("socket_#{user.id}_#{channel}", data)
  end

  def subscribed
    stream_for "socket_#{current_user.id}_#{params[:channel_id]}"
  end

  def receive(data)
    data.deep_symbolize_keys!
    return unless params[:channel_id].present?

    ::Jarvis.execute_trigger(
      :websocket,
      { input_vars: { "WS Receive Data" => data.reverse_merge(params) } },
      scope: [
        "user_id = #{current_user.id} AND (input ~* ? OR input = '*')",
        "\\m#{params[:channel_id]}\\M"
      ]
    )
  end
end
