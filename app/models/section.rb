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
    soft_name = name.to_s.gsub(/[^\w\s\d]/, "").downcase.squish
    next none if soft_name.blank?

    where(
      "LOWER(TRIM(REGEXP_REPLACE(REGEXP_REPLACE(name, '[^\\w\\s\\d]', '', 'g'), '\\s+', ' ', 'g'))) = ?",
      soft_name,
    )
  }

  before_save :set_sort_order
  after_commit :broadcast_commit

  validates :name, presence: true
  validates :color, presence: true

  def contrast_color
    ColorGenerator.contrast_text_color_on_background(color)
  end

  private

  def set_sort_order
    self.sort_order ||= list.max_sort_order + 1
  end

  def broadcast_commit
    return if do_not_broadcast

    ActionCable.server.broadcast "list_#{list_id}_json_channel", { list_data: list.serialize, timestamp: Time.current.to_i }

    rendered_message = ListsController.render template: "list_items/index", locals: { list: list }, layout: false
    ActionCable.server.broadcast "list_#{list_id}_html_channel", { list_html: rendered_message, timestamp: Time.current.to_i }
  end
end
