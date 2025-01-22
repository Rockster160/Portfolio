class JarvisChannel < ApplicationCable::Channel
  def self.broadcast(data, user=User.me)
    packet = data.is_a?(String) ? { say: data } : data
    packet = packet.is_a?(Symbol) ? { data: packet } : packet.as_json

    JarvisChannel.broadcast_to(user, packet)
  end

  def subscribed
    stream_for current_user
  end

  def command(data)
    Jarvis.command(current_user, data["words"])
  end
end
