class MonitorChannel < ApplicationCable::Channel
  def self.started(task)
    broadcast_to(
      task.user,
      id: task.uuid,
      loading: true,
    )
  end

  def self.send_error(user, task_id)
    broadcast_to(
      user,
      id: task_id,
      result: "[ico fa-exclamation font-size: 72px; color: red;]\nMonitor not found",
      error: true
    )
  end

  def self.send_task(task)
    broadcast_to(
      task.user,
      id: task.uuid,
      result: task.last_result,
      timestamp: task.last_ctx.dig(:vars, "timestamp:var").then { |ts|
        break ts if ts.is_a?(Numeric) # If it's a number
        break ts.to_f if ts.to_f > 0 # Or looks like a number
      } || task.last_trigger_at.to_i,
    )
    # This is VERY magic. If the task defines a "timestamp" variable, the monitor channel will
    #   send that instead, allowing us to set the timestamp on the cell
    # Other magic variables: `error` - What should it do?
  end

  def subscribed
    stream_for current_user
  end

  def broadcast(data)
    # This sends messages from Monitor JS to Socket listeners
    data.delete("action") # Action is `broadcast`
    channel = data.delete("channel")
    return unless current_user.present? && channel.present?

    SocketChannel.send_to(current_user, channel, data)
  end

  def execute(data) # Runs task with executing:true
    task = current_user.jarvis_tasks.anyfind(data["id"])

    ::Jarvis::Execute.call(task, input_vars: { "Pressed": true })
  rescue ActiveRecord::RecordNotFound
    MonitorChannel.send_error(current_user, data["id"])
  end

  def refresh(data) # Runs task with executing:false
    task = current_user.jarvis_tasks.anyfind(data["id"])

    ::Jarvis::Execute.call(task, input_vars: { "Pressed": false })
  rescue ActiveRecord::RecordNotFound
    MonitorChannel.send_error(current_user, data["id"])
  end

  def resync(data) # Pulls most recent result without Running
    task = current_user.jarvis_tasks.anyfind(data["id"])

    MonitorChannel.send_task(task)
  rescue ActiveRecord::RecordNotFound
    MonitorChannel.send_error(current_user, data["id"])
  end
end
