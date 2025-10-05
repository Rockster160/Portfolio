# == Schema Information
#
# Table name: box_tags
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  box_id     :bigint           not null
#  tag_id     :bigint           not null
#
class BoxTag < ApplicationRecord
  belongs_to :box
  belongs_to :tag, class_name: "InventoryTag"
end
