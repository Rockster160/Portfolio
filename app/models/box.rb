# == Schema Information
#
# Table name: boxes
#
#  id             :bigint           not null, primary key
#  data           :jsonb            not null
#  description    :text
#  empty          :boolean          default(TRUE), not null
#  hierarchy_data :jsonb            not null
#  hierarchy_ids  :jsonb            not null
#  name           :text             not null
#  notes          :text
#  sort_order     :integer          not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  parent_id      :bigint
#  user_id        :bigint           not null
#
class Box < ApplicationRecord
  include Orderable

  attr_accessor :reset_hierarchy

  belongs_to :user
  belongs_to :parent, class_name: "Box", optional: true
  has_many :boxes, dependent: :destroy, foreign_key: :parent_id, inverse_of: :parent

  before_save :set_hierarchy, if: :reset_hierarchy?
  before_save :cascade_hierarchy, if: :hierarchy_ids_changed?

  orderable sort_order: :desc, scope: ->(box) {
    box.parent&.boxes || box.user.boxes.where(parent_id: nil)
  }

  json_attributes :data, :hierarchy_data

  def contents
    boxes.ordered
  end

  def hierarchy
    (hierarchy_data.pluck(:name) + [name]).join(" > ")
  end

  def serialize(opts={})
    super.merge(hierarchy: hierarchy)
  end

  private

  def reset_hierarchy?
    return true if reset_hierarchy
    return true if parent_id_changed?
    return true if new_record?

    false
  end

  def set_hierarchy
    self.hierarchy_data = parent.hierarchy_data + [{ id: parent.id, name: parent.name }] if parent
    self.hierarchy_ids = ((parent&.hierarchy_ids || []) + [parent_id]).compact
    parent.update!(empty: false) if parent && parent.empty?
  end

  def cascade_hierarchy
    contents.each do |b|
      b.update(reset_hierarchy: true)
    end
  end
end
