class MonitorChannel < ApplicationCable::Channel
  def self.started(task)
    broadcast_to(
      task.user,
      id: task.id,
      loading: true,
    )
  end

  def self.send_task(task)
    broadcast_to(
      task.user,
      id: task.id,
      result: task.last_result,
      timestamp: task.last_trigger_at.to_i,
    )
  end

  def subscribed
    stream_for current_user
  end

  def receive(data)
    data.deep_symbolize_keys!
    return unless data[:channel_name].present?

    ::Jarvis.execute_trigger(
      :websocket,
      { input_vars: { "WS Receive Data" => data.reverse_merge(params) } },
      scope: [
        "user_id = #{current_user.id} AND (input ~* ? OR input = '*')",
        "\\m#{data[:channel_name]}\\M"
      ]
    )
  end

  def execute(data) # Runs task with executing:true
    task = current_user.jarvis_tasks.find(data["id"])

    ::Jarvis::Execute.call(task, input_vars: { "Executing?": true })
  end

  def refresh(data) # Runs task with executing:false
    task = current_user.jarvis_tasks.find(data["id"])

    ::Jarvis::Execute.call(task, input_vars: { "Executing?": false })
  end

  def resync(data) # Pulls most recent result without Running
    task = current_user.jarvis_tasks.find(data["id"])

    MonitorChannel.send_task(task)
  end
end
