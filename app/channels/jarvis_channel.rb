class JarvisChannel < ApplicationCable::Channel
  def subscribed
    stream_from "jarvis_channel"
  end

  def command(data)
    Jarvis.command(current_user, data["words"])
  end
end
