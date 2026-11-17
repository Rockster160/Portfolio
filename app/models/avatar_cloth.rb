# == Schema Information
#
# Table name: avatar_clothes
#
#  id         :integer          not null, primary key
#  color      :string
#  garment    :string
#  gender     :string
#  placement  :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  avatar_id  :integer
#

class AvatarCloth < ApplicationRecord
  belongs_to :avatar

  def self.to_components
    all.map { |cloth| { gender: cloth.gender, placement: cloth.placement, garment: cloth.garment, color: cloth.color } }
  end
end
