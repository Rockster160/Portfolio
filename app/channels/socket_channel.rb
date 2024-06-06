class SocketChannel < ApplicationCable::Channel
  # Trigger a disconnect when the pinging stops
  after_subscribe :connection_watcher
  CONNECTION_TIMEOUT = 10.seconds
  CONNECTION_PING_INTERVAL = 3.seconds
  periodically every: CONNECTION_PING_INTERVAL do
    @driver&.ping
    if Time.now - @_last_request_at > @_timeout
      # close_connection
      # self.disconnect
      connection.close
    end
  end
  def connection_watcher
    @_last_request_at ||= Time.now
    @_timeout = CONNECTION_TIMEOUT
    @driver = connection.instance_variable_get("@websocket").possible?&.instance_variable_get("@driver")
    @driver.on(:pong) { @_last_request_at = Time.now }
  end

  def self.send_to(user, channel, data)
    SocketChannel.broadcast_to("socket_#{user.id}_#{channel}", data)
  end

  def subscribed
    stream_for "socket_#{current_user.id}_#{params[:channel_id]}"
    trigger(params, :connected)
  end

  def unsubscribed
    trigger(params, :disconnected)
  end

  def receive(data)
    trigger(data, :receive)
    identifier = (
      if current_user
        "\e[36m[#{current_user.try(:username).presence || "User #{current_user.try(:id)}"}]"
      else
        "\e[31m[?]"
      end
    )
    ::PrettyLogger.info("\e[35m[WS]#{identifier}\n\e[0m#{PrettyLogger.pretty_message(data.deep_symbolize_keys)}")
  end

  private

  def trigger(data, state)
    data.try(:deep_symbolize_keys!)
    return unless params[:channel_id].present?

    receive_data = data.reverse_merge(params).except(:action)

    ::Jarvis.execute_trigger(
      :websocket,
      { input_vars: { "WS Receive Data" => receive_data, "Connection State" => state || "unset" } },
      scope: [
        "user_id = #{current_user.id} AND (input ~* ? OR input = '*')",
        "\\m#{params[:channel_id]}\\M"
      ]
    )
  end
end
