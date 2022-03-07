class FitnessChannel < ApplicationCable::Channel
  def subscribed
    stream_from "fitness_channel"
  end
end
