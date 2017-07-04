# == Schema Information
#
# Table name: avatars
#
#  id          :integer          not null, primary key
#  user_id     :integer
#  ears_url    :string
#  eyes_url    :string
#  body_url    :string
#  nose_url    :string
#  beard_url   :string
#  belt_url    :string
#  feet_url    :string
#  legs_url    :string
#  hands_url   :string
#  torso_url   :string
#  hair_url    :string
#  arms_url    :string
#  neck_url    :string
#  head_url    :string
#  weapons_url :string
#  back_url    :string
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#

class Avatar < ApplicationRecord
  belongs_to :user
end
