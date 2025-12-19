class SocketChannel < ApplicationCable::Channel
  # Trigger a disconnect when the pinging stops
  after_subscribe :connection_watcher
  CONNECTION_TIMEOUT = 10.seconds
  CONNECTION_PING_INTERVAL = 3.seconds
  periodically every: CONNECTION_PING_INTERVAL do
    @driver&.ping
    if Time.zone.now - @_last_request_at > @_timeout
      # close_connection
      # self.disconnect
      connection.close
    end
  end
  def connection_watcher
    @_last_request_at ||= Time.zone.now
    @_timeout = CONNECTION_TIMEOUT
    @driver = connection.instance_variable_get("@websocket").possible?&.instance_variable_get("@driver")
    @driver.on(:pong) { @_last_request_at = Time.zone.now }
  end
  # periodically every: CONNECTION_PING_INTERVAL do
  #   last_pong = connection.instance_variable_get(:@_last_pong_at)
  #   timeout   = connection.instance_variable_get(:@_ws_timeout) || CONNECTION_TIMEOUT
  #   driver = connection.instance_variable_get(:@_ws_driver)
  #   driver&.ping
  #   if last_pong && (Time.current - last_pong) > timeout
  #     # close_connection
  #     # self.disconnect
  #     trigger(params, :disconnected)
  #     connection.close
  #   end
  # end
  # def connection_watcher
  #   # Ensure this only gets set up once per connection, not once per subscription
  #   return if connection.instance_variable_get(:@_pong_watcher_setup)

  #   connection.instance_variable_set(:@_pong_watcher_setup, true)
  #   connection.instance_variable_set(:@_ws_timeout, CONNECTION_TIMEOUT)
  #   connection.instance_variable_set(:@_last_pong_at, Time.current)

  #   websocket = connection.instance_variable_get("@websocket")
  #   driver = websocket&.possible?&.instance_variable_get("@driver")
  #   connection.instance_variable_set(:@_ws_driver, driver)

  #   @_last_request_at ||= Time.zone.now
  #   @_timeout = CONNECTION_TIMEOUT
  #   @driver = connection.instance_variable_get("@websocket").possible?&.instance_variable_get("@driver")

  #   driver&.on(:pong) do
  #     connection.instance_variable_set(:@_last_pong_at, Time.current)
  #   end
  # end

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

  def receive(raw_data)
    data = raw_data.try(:deep_symbolize_keys!)
    return if data.nil?

    trigger(data, :receive)
  end

  private

  def trigger(data, state)
    data.try(:deep_symbolize_keys!)
    return if params[:channel_id].blank?

    receive_data = data.reverse_merge(params).except(:action).merge(connection_state: state || "unset")
    pretty_log_data(receive_data)

    ::Jil.trigger(current_user, :websocket, receive_data)
  end
end
