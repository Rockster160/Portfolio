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
  belongs_to :parent, class_name: "Box", optional: true
  has_many :items, class_name: "BoxItem", dependent: :destroy
  has_many :boxes, dependent: :destroy, foreign_key: :parent_id

  before_save :set_hierarchy, if: :parent_id_changed?

  # has_many :box_tags, dependent: :destroy
  # has_many :tags, through: :box_tags, source: :tag

  def contents
    (boxes + items).sort_by(&:sort_order)
  end

  def max_sort_order
    [
      boxes.maximum(:sort_order).to_i,
      items.maximum(:sort_order).to_i,
    ].max
  end

  def set_orderable
    self[:sort_order] ||= (parent&.max_sort_order || user.box_items.maximum(:sort_order).to_i) + 1
  end

  private

  def set_hierarchy
    self.hierarchy = parent.hierarchy + [parent_id]
  end
end
