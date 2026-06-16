class TeslaChannel < ApplicationCable::Channel
  def subscribed
    stream_from "tesla_channel"
  end

  def command(data)
    TeslaCommandWorker.perform_async(data["command"], data["params"])
  end

  def request
    TeslaCommand.command(:request, nil, true)
  end
end
