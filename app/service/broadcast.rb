class Broadcast
  def self.ping(channel, data={})
    channel = channel.to_s.underscore.gsub(/_channel$/, "")
    ActionCable.server.broadcast("#{channel}_channel", data)
  end

  def self.subscribers
    ActionCable.server.pubsub.send(:redis_connection).pubsub("channels", "user:*")
  end
end
