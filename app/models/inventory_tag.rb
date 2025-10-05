# == Schema Information
#
# Table name: inventory_tags
#
#  id         :bigint           not null, primary key
#  color      :text             not null
#  name       :text             not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class InventoryTag < ApplicationRecord
  belongs_to :user

  has_many :box_tags, dependent: :destroy
  has_many :item_tags, dependent: :destroy
end
