class LittleWorldChannel < ApplicationCable::Channel

  def subscribed
    stream_from "little_world_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def logged_in
    Avatar.find_by(id: params[:uuid]).try(:broadcast_movement)
  end

  def logged_out
    Avatar.find_by(id: params[:uuid]).try(:log_out)
  end
end
