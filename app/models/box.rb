# == Schema Information
#
# Table name: boxes
#
#  id             :bigint           not null
#  data           :jsonb            not null
#  description    :text
#  empty          :boolean          default(TRUE), not null
#  hierarchy      :text
#  hierarchy_data :jsonb            not null
#  hierarchy_ids  :jsonb            not null
#  name           :text             not null
#  notes          :text
#  param_key      :text             primary key
#  parent_key     :text
#  sort_order     :integer          not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  user_id        :bigint           not null
#
class Box < ApplicationRecord
  self.primary_key = "param_key"

  include Orderable

  attr_accessor :reset_hierarchy, :do_not_broadcast

  belongs_to :user
  belongs_to :parent, class_name: "Box", primary_key: :param_key, foreign_key: :parent_key, optional: true, inverse_of: :boxes
  has_many :boxes, primary_key: :param_key, foreign_key: :parent_key, inverse_of: :parent, dependent: :destroy
  # belongs_to :parent, class_name: "Box", optional: true
  # has_many :boxes, dependent: :destroy, foreign_key: :parent_id, inverse_of: :parent

  before_save :set_param_key, if: :new_record?
  before_save :set_hierarchy, if: :reset_hierarchy?
  before_save :cascade_hierarchy, if: :hierarchy_ids_changed?

  orderable sort_order: :desc, scope: ->(box) {
    box.parent&.boxes || box.user.boxes.where(parent_key: nil)
  }

  after_commit :broadcast_create, on: :create
  after_commit :broadcast_update, on: :update
  after_commit :broadcast_destroy, on: :destroy

  scope :within, ->(*box_ids) {
    where("hierarchy_ids @> ?", Array.wrap(box_ids).to_json)
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

  def self.full_reset
    Box.update_all(hierarchy: nil, hierarchy_data: [], hierarchy_ids: [])
    reset = ->(box) {
      box.update!(reset_hierarchy: true, empty: box.boxes.empty?)
      box.boxes.each { |b| reset.call(b) }
    }
    Box.where(parent_key: nil).find_each { |box| reset.call(box) }
  end

  def contents
    boxes.ordered
  end

  def level
    hierarchy_ids.size + 1
  end

  # def hierarchy
  #   (hierarchy_data.pluck(:name) + [name]).join(" > ")
  # end

  def serialize(opts={})
    result = super(opts.except(:include_hierarchy_ids))
    # Always include hierarchy_ids when requested (for search results with clickable breadcrumbs)
    result[:hierarchy_ids] = hierarchy_ids if opts[:include_hierarchy_ids]
    result
  end

  def to_param
    if param_key.blank?
      set_param_key
      save!
    end

    param_key
  end

  def broadcast!(action: :update, deleted: false)
    return if do_not_broadcast

    data = { box: serialize.merge(deleted: deleted), action: action, timestamp: Time.current.to_i }
    ActionCable.server.broadcast("inventory_#{user_id}_channel", data)
  end

  private

  def broadcast_create
    broadcast!(action: :create)
  end

  def broadcast_update
    broadcast!(action: :update)
  end

  def broadcast_destroy
    return if do_not_broadcast

    # For destroyed records, we need to build the data manually since serialize may not work
    data = {
      box: {
        id: id,
        param_key: param_key,
        parent_key: parent_key,
        deleted: true
      },
      action: :destroy,
      timestamp: Time.current.to_i
    }
    ActionCable.server.broadcast("inventory_#{user_id}_channel", data)
  end

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
    return true if @reset_hierarchy
    return true if parent_key_changed?
    return true if new_record?

    false
  end

  def set_hierarchy
    self.hierarchy_data = parent.hierarchy_data + [{ id: parent.param_key, name: parent.name }] if parent
    self.hierarchy_ids = ((parent&.hierarchy_ids || []) + [parent&.param_key]).compact
    self.hierarchy = (hierarchy_data.pluck(:name) + [name]).join(" > ")
    parent.update!(empty: false) if parent && parent.empty?
  end

  def cascade_hierarchy
    contents.each do |b|
      b.update(reset_hierarchy: true)
    end
  end
end
