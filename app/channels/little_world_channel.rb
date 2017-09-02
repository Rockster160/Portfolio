class LittleWorldChannel < ApplicationCable::Channel
  def subscribed
    current_avatar.log_in
    stream_from "little_world_channel"
    player_list = Rails.cache.read("player_list").to_a
    player_list += [current_avatar.uuid]
    Rails.cache.write("player_list", player_list.uniq)
  end

  def unsubscribed
    current_avatar.log_out
    player_list = Rails.cache.read("player_list").to_a
    player_list -= [current_avatar.uuid]
    Rails.cache.write("player_list", player_list.uniq)
  end

  def speak(data)
    message_text = data["message"].to_s.squish.first(256).gsub("<", "&lt;").presence
    return unless message_text.present?

    avatar = Avatar.find_by(uuid: data["uuid"])
    avatar.update(timestamp: data["timestamp"])
    message = LittleWorldsController.render(partial: 'message', locals: { author: avatar.try(:username), message: message_text, timestamp: avatar.try(:timestamp) })
    ActionCable.server.broadcast "little_world_channel", {uuid: data["uuid"], message: message, timestamp: avatar.try(:timestamp)}
  end
end
