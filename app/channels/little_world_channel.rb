class LittleWorldChannel < ApplicationCable::Channel

  def subscribed
    stream_from "little_world_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def logged_in
  end

  def logged_out
  end
end
