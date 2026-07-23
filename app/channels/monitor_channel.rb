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

    kick_whisper_refresh if params[:page].to_s.start_with?("/whisper")

    return unless current_user.me?

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
    ::Jil.trigger(
      current_user, :monitor, with_channel(data).merge({ execute: true }),
      auth: :userpass, auth_id: current_user.id
    )
  end

  def refresh(data) # Runs task with executing:false
    ::Jil.trigger(
      current_user, :monitor, with_channel(data).merge({ refresh: true }),
      auth: :userpass, auth_id: current_user.id
    )
  end

  def resync(data) # Pulls most recent result without Running
    ::Jil.trigger(
      current_user, :monitor, with_channel(data).merge({ resync: true }),
      auth: :userpass, auth_id: current_user.id
    )
  end

  private

  def kick_whisper_refresh
    ::Jil.trigger(
      User.me, :monitor,
      { channel: "whisper-durations", refresh: true },
      auth: :userpass, auth_id: current_user.id
    )
  end

  # Quick-actions widgets only know their `id`; the Task listener fast-path
  # for `monitor::<name>` matches on `trigger_data[:channel]`. Default it
  # from `id` so resync/refresh/execute from any client routes to the
  # right task instead of silently missing.
  def with_channel(data)
    sym_data = data.symbolize_keys
    sym_data[:channel] ||= sym_data[:id]
    sym_data
  end
end
