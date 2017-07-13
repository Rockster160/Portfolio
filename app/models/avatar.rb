# == Schema Information
#
# Table name: avatars
#
#  id         :integer          not null, primary key
#  user_id    :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

class Avatar < ApplicationRecord
  include CharacterBuilderHelper
  belongs_to :user
  has_many :clothes, class_name: "AvatarCloth"

  def update_by_builder(character)
    persisted? ? touch : save
    clothes.destroy_all
    character.to_components.each do |html_component|
      puts "#{html_component}".colorize(:red)
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

  def character
    character_outfit = outfit
    return unless character_outfit
    CharacterBuilder.new(character_outfit)
  end

end
