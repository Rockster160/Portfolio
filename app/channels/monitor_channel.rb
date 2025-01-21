class MonitorChannel < ApplicationCable::Channel
  # def self.send_error(user, task_id)
  #   broadcast_to(
  #     user,
  #     id: task_id,
  #     result: "[ico fa-exclamation font-size: 72px; color: red;]\nMonitor not found",
  #     error: true
  #   )
  # end

  def subscribed
    stream_for current_user

    last_sha = ::DataStorage[:last_sha]
    if last_sha != COMMIT_SHA
      ::DataStorage[:last_sha] = COMMIT_SHA
      ::Jil.trigger(User.me, :startup, { sha: COMMIT_SHA })
      ::Jarvis.say("Subscribed: Updated SHA")
    end
  end

  def broadcast(data)
    # This sends messages from Monitor JS to Socket listeners
    data.delete("action") # Action is `broadcast`
    channel = data.delete("channel")
    return unless current_user.present? && channel.present?

    SocketChannel.send_to(current_user, channel, data)
  end

  def execute(data) # Runs task with executing:true
    ::Jil.trigger(current_user.id, :monitor, data.symbolize_keys.merge({ execute: true }))
  end

  def refresh(data) # Runs task with executing:false
    ::Jil.trigger(current_user.id, :monitor, data.symbolize_keys.merge({ refresh: true }))
  end

  def resync(data) # Pulls most recent result without Running
    ::Jil.trigger(current_user.id, :monitor, data.symbolize_keys.merge({ resync: true }))
  end
end
