class SocketChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user, channel_id: params[:channel_id]
  end

  def receive(data)
    data.deep_symbolize_keys!
    return unless data[:channel_id].present?

    ::Jarvis.execute_trigger(
      :websocket,
      { input_vars: { "WS Receive Data" => data.reverse_merge(params) } },
      scope: [
        "user_id = #{current_user.id} AND (input ~* ? OR input = '*')",
        "\\m#{data[:channel_id]}\\M"
      ]
    )
  end
end
