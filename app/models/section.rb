# == Schema Information
#
# Table name: sections
#
#  id         :bigint           not null, primary key
#  color      :text             not null
#  name       :text             not null
#  sort_order :integer          not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  list_id    :bigint           not null
#
class Section < ApplicationRecord
  attr_accessor :do_not_broadcast

  belongs_to :list

  has_many :list_items, dependent: :nullify

  scope :ordered, -> { order("sections.sort_order DESC") }

  before_save :set_sort_order

  validates :name, presence: true
  validates :color, presence: true

  def serialize(opts={})
    super(
      only: [
        :id,
        :name,
        :color,
        :sort_order,
      ],
    )
  end

  def legacy_serialize
    as_json(only: [:id, :name, :color, :sort_order])
  end

  def contrast_color
    ColorGenerator.contrast_text_color_on_background(color)
  end

  private

  def set_sort_order
    self.sort_order ||= list.max_sort_order + 1
  end
end
