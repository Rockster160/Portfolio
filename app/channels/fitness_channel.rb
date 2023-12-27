# Deprecated! Use Monitors + Jil instead
class FitnessChannel < ApplicationCable::Channel
  def subscribed
    stream_from "fitness_channel"
  end

  def request(data)
    ::FitnessBroadcast.broadcast
  end
end
