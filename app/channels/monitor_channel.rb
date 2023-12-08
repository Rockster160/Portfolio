class MonitorChannel < ApplicationCable::Channel
  # NOTE: The below should be used to determine when a connection is lost
  # Use this to figure if the garage loses connection.
  # Can also do websocket triggers - include "connection:bool" as an argument
  # after_subscribe :connection_monitor
  # CONNECTION_TIMEOUT = 10.seconds
  # CONNECTION_PING_INTERVAL = 5.seconds
  # periodically every: CONNECTION_PING_INTERVAL do
  #   @driver&.ping
  #   if Time.now - @_last_request_at > @_timeout
  #     connection.disconnect
  #   end
  # end
  # def connection_monitor
  #   @_last_request_at ||= Time.now
  #   @_timeout = CONNECTION_TIMEOUT
  #   @driver = connection.instance_variable_get('@websocket').possible?&.instance_variable_get('@driver')
  #   @driver.on(:pong) { @_last_request_at = Time.now }
  # end
  def self.started(task)
    broadcast_to(
      task.user,
      id: task.uuid,
      loading: true,
    )
  end

  def self.send_task(task)
    broadcast_to(
      task.user,
      id: task.uuid,
      result: task.last_result,
      timestamp: task.last_trigger_at.to_i,
    )
  end

  def subscribed
    stream_for current_user
  end

  def execute(data) # Runs task with executing:true
    task = current_user.jarvis_tasks.anyfind(data["id"])

    ::Jarvis::Execute.call(task, input_vars: { "Executing?": true })
  end

  def refresh(data) # Runs task with executing:false
    task = current_user.jarvis_tasks.anyfind(data["id"])

    ::Jarvis::Execute.call(task, input_vars: { "Executing?": false })
  end

  def resync(data) # Pulls most recent result without Running
    task = current_user.jarvis_tasks.anyfind(data["id"])

    MonitorChannel.send_task(task)
  end
end
