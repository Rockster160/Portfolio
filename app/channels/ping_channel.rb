class PingChannel < ApplicationCable::Channel
  def subscribed
    stream_from "ping_channel"
  end

  def receive(data)
    channel = data["channel"]
    raw_json = (" " + (data["data"] || data).to_s).gsub(/\:(\w+)/, "\"\\1\"").gsub(/([^\"])(\w+)([^\"]):/, "\\1\"\\2\\3\":")
    raw_json = "{#{raw_json}}" unless raw_json.squish[0].in?(["{", "["])
    json = JSON.parse(raw_json) rescue { data: data["data"] || data }

    ActionCable.server.broadcast("#{channel}_channel", json)
    ActionCable.server.broadcast("ping_channel", "Sending #{channel}: #{json}")
  end
end
