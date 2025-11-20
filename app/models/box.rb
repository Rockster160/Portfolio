# == Schema Information
#
# Table name: boxes
#
#  id             :bigint           not null, primary key
#  data           :jsonb            not null
#  description    :text
#  empty          :boolean          default(TRUE), not null
#  hierarchy      :text
#  hierarchy_data :jsonb            not null
#  hierarchy_ids  :jsonb            not null
#  name           :text             not null
#  notes          :text
#  param_key      :text
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

  before_save :set_param_key, if: :new_record?
  before_save :set_hierarchy, if: :reset_hierarchy?
  before_save :cascade_hierarchy, if: :hierarchy_ids_changed?

  orderable sort_order: :desc, scope: ->(box) {
    box.parent&.boxes || box.user.boxes.where(parent_id: nil)
  }

  search_terms :id, :name, :hierarchy, :description, :notes

  json_attributes :data, :hierarchy_data

  validates :name, presence: true

  def self.from_key(keys)
    if keys.is_a?(::Array)
      keys = keys.map { |k| k.upcase.gsub("0", "O").gsub("1", "I") }
      ilike(param_key: keys)
    else
      ilike(param_key: keys.upcase.gsub("0", "O").gsub("1", "I")).take!
    end
  end

  def contents
    boxes.ordered
  end

  def level
    hierarchy_ids.size + 1
  end

  def hierarchy
    (hierarchy_data.pluck(:name) + [name]).join(" > ")
  end

  def serialize(opts={})
    super.merge(hierarchy: hierarchy)
  end

  def to_param
    if param_key.blank?
      set_param_key
      save!
    end

    param_key
  end

  private

  def set_param_key
    param_length = 4 # 34^4 = 1,336,336 possible combinations.
    # We can expand up to 7 characters without losing QR size.
    # 34^4 =      1,336,336
    # 34^7 = 52,523,350,144
    self.param_key ||= loop do
      chars = [*"A".."Z", *"2".."9"] # Exclude 0,1, map to O,I when we do lookup
      random_key = param_length.times.map { chars.sample }.join

      break random_key unless ::Box.exists?(param_key: random_key)

      SlackNotifier.notify("Regenerating box param_key collision: #{random_key}. Total boxes: #{::Box.count}.")
    end
  end

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
