class JarvisChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user
  end

  def command(data)
    Jarvis.command(current_user, data["words"])
  end
end
