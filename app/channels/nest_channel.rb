class NestChannel < ApplicationCable::Channel
  def subscribed
    stream_from "nest_channel"
  end

  def command(data)
    NestCommandWorker.perform_async(data["settings"])
  end
end
