# == Schema Information
#
# Table name: box_items
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  box_id     :bigint           not null
#  user_id    :bigint           not null
#
class BoxItem < ApplicationRecord
  include Orderable

  belongs_to :user
  belongs_to :box

  has_many :item_tags, dependent: :destroy
  has_many :tags, through: :item_tags, source: :tag

  def set_orderable
    self[:sort_order] ||= box.max_sort_order + 1
  end
end
