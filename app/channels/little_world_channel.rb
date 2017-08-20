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
    message = data["message"].to_s.squish.first(256).gsub("<", "&lt;").presence
    return unless message.present?

    ActionCable.server.broadcast "little_world_channel", {uuid: data["uuid"], message: message}
  end
end
