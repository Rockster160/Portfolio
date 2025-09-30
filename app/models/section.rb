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
  scope :where_soft_name, ->(name) {
    where("LOWER(TRIM(REGEXP_REPLACE(name, '\\s+', ' ', 'g'))) = ?", name.to_s.downcase.squish)
  }

  before_save :set_sort_order
  after_commit :broadcast_commit

  validates :name, presence: true
  validates :color, presence: true

  def serialize(_opts={})
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

  def broadcast_commit
    return if do_not_broadcast

    ActionCable.server.broadcast "list_#{self.list_id}_json_channel", { list_data: list.legacy_serialize, timestamp: Time.current.to_i }

    rendered_message = ListsController.render template: "list_items/index", locals: { list: self.list }, layout: false
    ActionCable.server.broadcast "list_#{self.list_id}_html_channel", { list_html: rendered_message, timestamp: Time.current.to_i }
  end
end
