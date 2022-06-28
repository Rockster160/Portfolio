class JarvisChannel < ApplicationCable::Channel
  def subscribed
    stream_from "jarvis_channel"
  end

  def command(data)
    response, jdata = Jarvis.command(current_user, data["words"])

    ActionCable.server.broadcast("jarvis_channel", response: response, data: jdata)
  end
end
