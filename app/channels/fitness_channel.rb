class FitnessChannel < ApplicationCable::Channel
  def subscribed
    stream_from "fitness_channel"
  end

  def request(data)
    ActionEventBroadcastWorker.perform_async
  end
end
