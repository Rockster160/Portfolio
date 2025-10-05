# == Schema Information
#
# Table name: item_tags
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  item_id    :bigint           not null
#  tag_id     :bigint           not null
#
class ItemTag < ApplicationRecord
  belongs_to :item
  belongs_to :tag, class_name: "InventoryTag"
end
