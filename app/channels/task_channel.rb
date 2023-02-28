class TaskChannel < ApplicationCable::Channel
  def subscribed
    stream_from "task_#{params[:channel_id]}_channel"
  end

  def receive(data)
    ::Jarvis.execute_trigger(
      :websocket,
      data,
      scope: { name: "task_#{params[:channel_id]}_channel" }
    )
    # ActionCable.server.broadcast("jarvis_channel", { say: data })
  end
end
# ActionCable.server.broadcast("task_#{btn_id}_channel", { rgb: "0,255,0", for_ms: 1000 })
# ActionCable.server.broadcast("task_abcd_channel", {rgb: "255,0,0", for_ms: 4500})
