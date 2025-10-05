# == Schema Information
#
# Table name: boxes
#
#  id          :bigint           not null, primary key
#  data        :jsonb            not null
#  description :text
#  hierarchy   :jsonb            not null
#  name        :text             not null
#  notes       :text
#  sort_order  :integer          not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  parent_id   :bigint
#  user_id     :bigint           not null
#
class Box < ApplicationRecord
  include Orderable

  belongs_to :user
  has_many :items, class_name: "BoxItem", dependent: :destroy
  has_many :boxes, dependent: :destroy

  has_many :box_tags, dependent: :destroy
  has_many :tags, through: :box_tags, source: :tag

  def max_sort_order
    [
      boxes.maximum(:sort_order).to_i,
      items.maximum(:sort_order).to_i,
    ].max
  end

  def set_orderable
    self[:sort_order] ||= (box&.max_sort_order || user.box_items.maximum(:sort_order).to_i) + 1
  end
end
