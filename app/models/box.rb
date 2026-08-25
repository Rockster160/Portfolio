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

  # Photos of what's actually in the box - see BoxImage for why they hang off a
  # row of their own rather than `has_many_attached` here.
  has_many :images, class_name: "BoxImage", primary_key: :param_key, foreign_key: :box_key, inverse_of: :box, dependent: :destroy

  before_save :set_param_key, if: :new_record?
  before_save :set_hierarchy, if: :reset_hierarchy?
  before_save :cascade_hierarchy, if: :hierarchy_ids_changed?
  before_save -> { self.parent_key = parent_key.presence }, if: :parent_key_changed?

  # `empty` is what makes a row read as an item rather than a container, and
  # `set_hierarchy` only ever clears it on the box being moved INTO. The box
  # something moved out of kept claiming contents it no longer had - the
  # Inventory app patched that from the outside with a `reset_empty` param on
  # the request, so it only ever held for a move made through that one screen.
  after_destroy :refresh_former_parent!
  after_save :refresh_former_parent!, if: :saved_change_to_parent_key?

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

  # One extra pair of queries for a whole level of the tree instead of two per
  # box. Every place that renders boxes carrying photos wants this.
  scope :with_photos, -> { includes(images: { file_attachment: :blob }) }

  validates :name, presence: true

  def self.from_key(keys)
    if keys.is_a?(::Array)
      keys = keys.map { |k| k.to_s.upcase.gsub("0", "O").gsub("1", "I") }
      ilike(param_key: keys)
    else
      ilike(param_key: keys.to_s.upcase.gsub("0", "O").gsub("1", "I")).take!
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
    boxes.ordered.with_photos
  end

  # Everything underneath, parents before children, which is the order they have
  # to come BACK in - a child recreated before its parent has no hierarchy to
  # compute. Reads the whole user's boxes once and walks them in memory rather
  # than a query per level.
  def descendants
    pool = user.boxes.where.not(param_key: param_key).ordered.to_a
    found = []
    frontier = [param_key]
    until frontier.empty?
      children = pool.select { |b| frontier.include?(b.parent_key) }
      break if children.empty?

      found.concat(children)
      frontier = children.map(&:param_key)
    end
    found
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
    result[:images] = images_wire
    result
  end

  # `sort_by` rather than the `ordered` scope: a scope on a preloaded
  # association issues a fresh query per box, which is the N+1 `with_photos`
  # exists to avoid.
  def images_wire
    images.sort_by(&:created_at).filter_map(&:wire)
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

  # The box this one just left (or, on destroy, the one it was in) goes back to
  # reading as an item when nothing is left inside it.
  def refresh_former_parent!
    key = destroyed? ? parent_key : saved_change_to_parent_key&.first
    return if key.blank?

    former = ::Box.find_by(param_key: key)
    return if former.nil? || former.param_key == param_key

    was_empty = former.boxes.none?
    former.update!(empty: was_empty) if former.empty != was_empty
  end

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
      box:       {
        id:         id,
        param_key:  param_key,
        parent_key: parent_key,
        deleted:    true,
      },
      action:    :destroy,
      timestamp: Time.current.to_i,
    }
    ActionCable.server.broadcast("inventory_#{user_id}_channel", data)
  end

  def set_param_key
    param_length = 4 # 34^4 = 1,336,336 possible combinations.
    # We can expand up to 7 characters without losing QR size.
    # 34^4 =      1,336,336
    # 34^7 = 52,523,350,144
    self.param_key ||= loop do
      chars = [*"A".."Z", *"2".."9"] # Exclude 0,1: map to O,I when we do lookup
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
    # Cleared rather than left alone when there's no parent. Moving a box out to
    # the top level ran this with `parent` nil, which skipped the assignment
    # entirely and left the OLD crumbs in place - so `hierarchy_ids` emptied and
    # `hierarchy` on the very next line rebuilt itself from the stale trail. A
    # tote dragged out of the basement went on reading "Basement > Camping Tote"
    # with nothing above it.
    self.hierarchy_data = parent ? parent.hierarchy_data + [{ id: parent.param_key, name: parent.name }] : []
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
