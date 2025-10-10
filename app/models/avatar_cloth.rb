# == Schema Information
#
# Table name: avatar_clothes
#
#  id         :integer          not null, primary key
#  avatar_id  :integer
#  gender     :string
#  placement  :string
#  garment    :string
#  color      :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

class AvatarCloth < ApplicationRecord
  belongs_to :avatar

  def self.to_components
    all.map { |cloth| { gender: cloth.gender, placement: cloth.placement, garment: cloth.garment, color: cloth.color } }
  end
end
