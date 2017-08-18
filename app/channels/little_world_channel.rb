class LittleWorldChannel < ApplicationCable::Channel

  def subscribed
    stream_from "little_world_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def speak(data)
    message = data["message"].to_s.squish.presence
    return unless message.present?

    ActionCable.server.broadcast "little_world_channel", {uuid: data["uuid"], message: message}
  end

  def logged_in
    Avatar.find_by(id: params[:uuid]).try(:broadcast_movement)
  end

  def logged_out
    Avatar.find_by(id: params[:uuid]).try(:log_out)
  end
end
