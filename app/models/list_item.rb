# == Schema Information
#
# Table name: list_items
#
#  id             :integer          not null, primary key
#  amount         :integer
#  category       :string
#  deleted_at     :datetime
#  formatted_name :text
#  important      :boolean          default(FALSE)
#  name           :text
#  permanent      :boolean          default(FALSE)
#  sort_order     :integer
#  created_at     :datetime
#  updated_at     :datetime
#  list_id        :integer
#  section_id     :bigint
#

class ListItem < ApplicationRecord
  attr_accessor :do_not_broadcast

  belongs_to :list
  belongs_to :section, optional: true

  before_save :set_sort_order, :normalize_values
  after_commit :broadcast_commit

  validates :name, presence: true

  default_scope { where(deleted_at: nil) }

  scope :ordered, -> { order("list_items.sort_order DESC NULLS LAST") }
  scope :important, -> { where(important: true) }
  scope :unimportant, -> { where.not(important: true) }

  def self.by_formatted_name(name)
    find_by(formatted_name: name.to_s.downcase.gsub(/[ '",.]/i, ""))
  end

  def self.by_name_then_update(params)
    old_item = by_data(params)

    if old_item.present?
      old_item.update(params.merge(deleted_at: nil, sort_order: nil))
      old_item.notify_jil(:added)
    else
      create(params).notify_jil(:added)
    end
  end

  def self.by_data(params, deleted: true)
    q = deleted ? with_deleted : all
    if params.is_a?(Hash) || params.is_a?(ActionController::Parameters)
      q.find_by(id: params[:id]) || q.by_formatted_name(params[:name])
    else
      q.by_formatted_name(params.to_s)
    end
  end

  def self.add(full_item_name)
    section = nil
    if (section_name = full_item_name[/^\s*\[(.*?)\]/, 1]).present?
      if (list_id = new.list_id).present? # extract list_id from scoped query
        section = Section.where_soft_name(section_name).find_by(list_id: list_id)
      end
    end

    item_name = full_item_name.sub(/\[#{section_name}\]\s*/, "").squish if section.present?
    item_name ||= full_item_name

    old_item = by_data(item_name)
    old_item ||= by_data(full_item_name) if item_name != full_item_name
    old_item.section = section if old_item.present? && section.present?

    if old_item.present?
      old_item.update(name: item_name, deleted_at: nil, sort_order: nil) if old_item.name != item_name || old_item.deleted_at? || old_item.sort_order != old_item.list.max_order
      old_item.update(section: section) if old_item.section != section && section.present?
      old_item.notify_jil(:added)
    else
      create(name: item_name, section: section).notify_jil(:added)
    end
  end

  def self.remove(item_name)
    old_item = by_data(item_name, deleted: false) || by_data(item_name)
    return if old_item.nil?

    old_item.notify_jil(:removed) if old_item.soft_destroy
    old_item
  end

  def self.toggle(item_name)
    old_item = by_data(item_name)

    if old_item.present? && !old_item.deleted?
      old_item.soft_destroy
      old_item.notify_jil(:removed)
    elsif old_item.present?
      old_item.update({ name: item_name }.merge(deleted_at: nil, sort_order: nil))
      old_item.notify_jil(:added)
    else
      create(name: item_name).notify_jil(:added)
    end
  end

  def serialize(opts={})
    super({
      only: [
        :id,
        :name,
        :category,
        :section_id,
        :important,
        :permanent,
        :sort_order,
        :deleted_at,
      ],
    }.merge(opts))
  end

  def jil_serialize(additional={})
    serialize(include: { list: { only: [:id, :name, :description] } }).merge(additional)
  end

  # Fire the same Jil `:item` trigger the list controllers fire, so items
  # created or removed through model paths (Jil `List.add`/`toggle`/`remove`,
  # SMS, recipes, webhooks, list builders) drive the same automations as
  # UI/API adds. Fires once per list owner (a list can be co-owned), so every
  # owner's tasks run regardless of who created the item. No-op when the item
  # never persisted or the list has no owner. Returns self so callers chain.
  def notify_jil(action)
    return self unless persisted?

    list&.owners&.each { |owner|
      ::Jil.trigger(owner, :item, jil_serialize(action: action), auth: :trigger)
    }
    self
  end

  def self.with_deleted
    unscope(where: :deleted_at)
  end

  def deleted?
    deleted_at?
  end

  def soft_destroy
    return if deleted?

    update(deleted_at: Time.current)
  end

  def checked=(new_val)
    if new_val.to_s == "true"
      update(deleted_at: DateTime.current) unless permanent?
    else
      update(deleted_at: nil)
    end
  end

  def options
    {
      important: "When set, this item will automatically appear at the top of the list regardless of the sort order.",
      permanent: "When set, this item will not be removed from list when checking it. Instead, it will appear toggled/selected on your page, but when reloading the page the item will still be present. This also prevents the item from being removed on other user's pages that are sharing the list.",
    }
  end

  private

  def set_sort_order
    self.sort_order ||= list.max_sort_order + 1
  end

  def normalize_values
    self.formatted_name = name.downcase.gsub(/[ '",.]/i, "")
    self.category = category.squish.titleize.presence if category
    true
  end

  def broadcast_commit
    return if do_not_broadcast

    ActionCable.server.broadcast "list_#{list_id}_json_channel", { list_data: list.serialize, timestamp: Time.current.to_i }

    list_item_attrs = attributes.symbolize_keys.slice(:important, :permanent, :category, :name)
    ActionCable.server.broadcast "list_item_#{id}_channel", { list_item: list_item_attrs }

    rendered_message = ListsController.render template: "list_items/index", locals: { list: list }, layout: false
    ActionCable.server.broadcast "list_#{list_id}_html_channel", { list_html: rendered_message, timestamp: Time.current.to_i }
  end
end
