# == Schema Information
#
# Table name: list_items
#
#  id             :integer          not null, primary key
#  name           :string(255)
#  list_id        :integer
#  created_at     :datetime
#  updated_at     :datetime
#  sort_order     :integer
#  formatted_name :string
#  deleted_at     :datetime
#  important      :boolean          default(FALSE)
#  permanent      :boolean          default(FALSE)
#  schedule       :string
#  category       :string
#  schedule_next  :datetime
#

class ListItem < ApplicationRecord
  acts_as_paranoid
  attr_accessor :do_not_broadcast, :do_not_bump_order
  belongs_to :list

  before_save :set_sort_order, :normalize_values
  after_commit :reorder_conflict_orders
  after_commit :broadcast_commit

  validates :name, presence: true

  scope :ordered, -> { order("list_items.important DESC, list_items.sort_order DESC") }
  scope :important, -> { where(important: true) }
  scope :unimportant, -> { where.not(important: true) }

  def self.by_formatted_name(name)
    find_by(formatted_name: name.to_s.downcase.gsub(/[^a-z0-9]/i, ""))
  end

  def self.by_name_then_update(params)
    old_item = with_deleted.find_by(id: params[:id]) || with_deleted.by_formatted_name(params[:name])

    if old_item.present?
      old_item.update(params.merge(deleted_at: nil, sort_order: nil))
      old_item
    else
      create(params)
    end
  end

  def checked=(new_val)
    if new_val.to_s == "true"
      update(deleted_at: DateTime.current) unless permanent?
    else
      update(deleted_at: nil)
    end
  end

  def schedule=(schedule_params)
    return if schedule_params.blank?
    interval = schedule_params["repeat-interval"].to_i
    interval = 1 if interval <= 0
    hour = schedule_params["repeat-hour"].to_i
    minute = schedule_params["repeat-minute"].to_i
    meridian = schedule_params["meridian"] || "AM"
    repeat_type = schedule_params["repeat-type"].to_sym if schedule_params["repeat-type"].in?(["minutely", "hourly", "daily", "weekly", "monthly"])
    return if repeat_type.nil?

    schedule_start = Time.zone.parse("#{hour}:#{minute} #{meridian}")
    new_schedule = IceCube::Schedule.new(schedule_start)
    rule = IceCube::Rule.send(repeat_type, interval)

    interval_details = schedule_params[repeat_type]
    if interval_details.present?
      case repeat_type
      when :weekly
        rule.day(*interval_details[:day]&.keys.to_a.map(&:to_i))
      when :monthly
        if interval_details[:type] == "daily"
          rule.day_of_month(*interval_details[:day].keys.map(&:to_i))
        elsif interval_details[:type] == "weekly"
          day_of_week_hash = {}
          interval_details[:week].each do |day_of_week, day_hash|
            days = day_hash[:day].keys
            days.each do |day|
              day_of_week_hash[day] ||= []
              day_of_week_hash[day] << day_of_week
            end
          end
          rule.day_of_week(day_of_week_hash)
        end
      end
    end

    new_schedule.add_recurrence_rule(rule)

    @schedule = nil
    super(new_schedule.to_ical)
    set_next_occurrence
  end

  def schedule
    @schedule ||= IceCube::Schedule.from_ical(super) rescue nil
    # to_s => Every 2 days...
  end

  def schedule_in_words
    words = schedule.to_s
    # Remove redundant text here, if it gets annoying.
    "#{words} at #{schedule.start_time.strftime("%-l:%M %p")}"
  end

  def set_next_occurrence
    return unless schedule
    self.schedule_next = schedule.next_occurrence
  end

  def jsonify
    name
  end

  def options
    {
      important: "When set, this item will automatically appear at the top of the list regardless of the sort order.",
      permanent: "When set, this item will not be removed from list when checking it. Instead, it will appear toggled/selected on your page, but when reloading the page the item will still be present. This also prevents the item from being removed on other user's pages that are sharing the list.  (Does not work if a schedule is set.)"
    }
  end

  private

  def set_sort_order
    self.sort_order ||= list.list_items.max_by(&:sort_order).try(:sort_order).to_i + 1
  end

  def normalize_values
    self.formatted_name = name.downcase.gsub(/[^a-z0-9]/i, "")
    self.category = self.category.squish.titleize.presence if self.category
    self.permanent = false if self.schedule.present?
    true
  end

  def broadcast_commit
    return if do_not_broadcast || do_not_bump_order
    rendered_message = ListsController.render template: "list_items/index", locals: { list: self.list }, layout: false
    ActionCable.server.broadcast "list_#{self.list_id}_channel", list_html: rendered_message
    ActionCable.server.broadcast "list_item_#{self.id}_channel", list_item: self.attributes.symbolize_keys.slice(:important, :permanent, :category, :name).merge(schedule: self.schedule_in_words)
  end

  def reorder_conflict_orders
    return if do_not_bump_order
    conflicted_items = list.list_items.where.not(id: self.id).where(sort_order: self.sort_order)
    if conflicted_items.any?
      do_not_broadcast = true
      conflicted_items.each do |conflicted_item|
        conflicted_items.update(sort_order: conflicted_item.sort_order + 1, do_not_broadcast: true)
      end
    else
      do_not_broadcast = false
    end
  end

end
