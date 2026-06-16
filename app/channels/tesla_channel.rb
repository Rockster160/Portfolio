class TeslaChannel < ApplicationCable::Channel
  # Tesla integration is restricted to User.me. Non-me subscribers are
  # rejected at subscription time, and the action methods double-check in
  # case the connection user changes mid-stream.
  def subscribed
    return reject unless me?

    stream_from "tesla_channel"
  end

  def command(data)
    return unless me?

    TeslaCommandWorker.perform_async(data["command"], data["params"])
  end

  def request
    return unless me?

    TeslaCommand.command(:request, nil, true)
  end

  private

  def me?
    current_user&.me?
  end
end
