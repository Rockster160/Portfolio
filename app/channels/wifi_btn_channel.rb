class WifiBtnChannel < ApplicationCable::Channel
  def subscribed
    stream_from "wifi_btn_#{params[:channel_id]}_channel"
  end

  def receive(data)
    ActionCable.server.broadcast("jarvis_channel", { say: data })
  end
end
# ActionCable.server.broadcast("wifi_btn_#{btn_id}_channel", { rgb: "0,255,0", for_ms: 1000 })
