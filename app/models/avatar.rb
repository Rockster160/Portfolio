# == Schema Information
#
# Table name: avatars
#
#  id           :integer          not null, primary key
#  user_id      :integer
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  location_x   :integer
#  location_y   :integer
#  timestamp    :string
#  uuid         :integer          not null
#  from_session :boolean
#

class Avatar < ApplicationRecord
  include CharacterBuilderHelper
  belongs_to :user, optional: true
  has_many :clothes, class_name: "AvatarCloth"

  after_initialize :set_uuid

  scope :logged_in, -> { return none;where(uuid: Rails.cache.read("player_list").to_a) }
  scope :from_session, -> { where(from_session: true) }
  scope :not_session, -> { where("from_session = false OR from_session IS NULL") }

  def self.default_character
    CharacterBuilder.new(CharacterBuilder.default_outfit)
  end

  def using_default_outfit?
    return true if clothes.none?
  end

  def update_by_builder(character)
    persisted? ? touch : save
    clothes.destroy_all
    character.to_components.each do |html_component|
      clothes.create(gender: html_component[:gender], placement: html_component[:placement], garment: html_component[:garment], color: html_component[:color])
    end
  end

  def components
    clothes.to_components
  end

  def outfit
    return unless clothes.many?
    building_outfit = {
      gender: nil,
      body: nil,
      clothing: {
        # back: { garment: "", color: "" },
        # beard: { garment: "", color: "" },
      }
    }
    components.each do |component|
      if component[:placement] == "body"
        building_outfit[:gender] = component[:gender]
        building_outfit[:body] = component[:garment]
      else
        building_outfit[:clothing][component[:placement]] = { garment: component[:garment], color: component[:color] }
      end
    end
    building_outfit
  end

  def character(random: false)
    character_outfit = outfit || CharacterBuilder.default_outfit
    CharacterBuilder.new(character_outfit, { random: random })
  end

  def username
    user.try(:username).presence || "Guest#{uuid}"
  end

  def player_details
    { x: location_x, y: location_y, timestamp: timestamp, uuid: uuid, username: username }
  end

  def broadcast_movement
    ActionCable.server.broadcast "little_world_channel", player_details
  end

  def log_in
    broadcast_movement
  end

  def log_out
    ActionCable.server.broadcast "little_world_channel", { uuid: uuid, log_out: true }
  end

  private

  def set_uuid
    return if uuid.present?
    self.uuid = loop do
      new_uuid = rand(100000..999999)
      break new_uuid if Avatar.where(uuid: new_uuid).none?
    end
  end

end
