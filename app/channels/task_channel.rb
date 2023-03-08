class TaskChannel < ApplicationCable::Channel
  def subscribed
    stream_from "task_#{params[:channel_id]}_channel"
  end

  def receive(data)
    data.deep_symbolize_keys!
    ::Jarvis.execute_trigger(
      :websocket,
      { input_vars: { "WS Receive Data" => data } },
      scope: ["input ~* ? OR input = '*'", "\\m#{params[:channel_id]}\\M"]
    )
  end
end
# ActionCable.server.broadcast("task_#{btn_id}_channel", { rgb: "0,255,0", for_ms: 1000 })
# ActionCable.server.broadcast("task_abcd_channel", {rgb: "255,0,0", for_ms: 4500})
# ::Jarvis.execute_trigger(
#   :websocket,
#   { input_vars: { "WS Receive Data" => { btn_id: :abcd } } },
#   scope: { input: "abcd" }
# )
