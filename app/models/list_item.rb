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
#  timezone       :integer
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
    self.schedule_next = nil
    return super(nil) if schedule_params.blank?
    interval = schedule_params["interval"].to_i
    interval = 1 if interval <= 0
    timezone = schedule_params["timezone"].to_i
    self.timezone = timezone
    meridian = schedule_params["meridian"] || "AM"
    hour = schedule_params["hour"].to_i
    hour -= 12 if hour > 12
    hour += 12 if meridian == "PM"
    minute = schedule_params["minute"].to_i
    repeat_type = schedule_params["type"].to_sym if schedule_params["type"].in?(["minutely", "hourly", "daily", "weekly", "monthly"])
    return if repeat_type.nil?

    Rails.logger.warn("#{hour}".colorize(:red))
    Rails.logger.warn("#{minute}".colorize(:red))
    schedule_start = Time.zone.now.utc - 24.hours
    schedule_start = schedule_start.change(hour: hour, min: minute)
    schedule_start += timezone
    Rails.logger.warn("#{timezone}".colorize(:red))
    Rails.logger.warn("#{schedule_start}".colorize(:red))
    new_schedule = IceCube::Schedule.new(schedule_start)
    rule = IceCube::Rule.send(repeat_type, interval)

    interval_details = schedule_params[repeat_type]
    if interval_details.present?
      case repeat_type
      when :weekly
        rule.day(*interval_details[:day].to_a.map(&:to_i))
      when :monthly
        if interval_details[:type] == "daily"
          rule.day_of_month(*interval_details[:day].map(&:to_i)) if interval_details.key?(:day)
        elsif interval_details[:type] == "weekly"
          deep_numerify_keys = interval_details[:week]&.each_with_object({}) do |(day_of_week, idxs_of_week), deep_numerify|
            deep_numerify[day_of_week.to_i] = idxs_of_week.map(&:to_i)
          end
          rule.day_of_week(deep_numerify_keys) if interval_details.key?(:week)
        end
      end
    end

    new_schedule.add_recurrence_rule(rule)

    @schedule = nil
    @schedule_options = nil
    super(new_schedule.to_ical)
    set_next_occurrence
  end

  def schedule
    return if super.nil?
    @schedule ||= IceCube::Schedule.from_ical(super) rescue nil
  end

  def default_schedule_options
    {
      interval: 1,
      type: :daily,
      minute: "00",
      week_days: [],
      days_of_week: [],
      days_of_month: []
    }
  end

  def schedule_options
    @schedule_options ||= begin
      options = {}
      rule = schedule.try(:rrules).try(:first).try(:to_hash) || {}
      options[:interval] = rule[:interval]
      options[:days_of_week] = rule.dig(:validations, :day_of_week)
      options[:days_of_month] = rule.dig(:validations, :day_of_month)
      options[:week_days] = rule.dig(:validations, :day)
      options[:type] = rule[:rule_type].to_s.gsub(/IceCube::|Rule/, "").downcase

      start_time = schedule.start_time rescue nil
      if start_time
        options[:hour] = start_time.hour > 12 ? start_time.hour - 12 : start_time.hour
        options[:minute] = start_time.min.to_s.rjust(2, "0")
        options[:meridian] = start_time.hour >= 12 ? "PM" : "AM"
        options[:timezone] = timezone
      end

      options.reject { |k,v| v.blank? }.reverse_merge(default_schedule_options)
    end
  end

  def schedule_in_words
    return "No schedule set - This item is not recurring." if schedule.nil?
    words = schedule.to_s
    # Remove redundant text here, if it gets annoying.
    "#{words} at #{schedule.start_time.strftime("%-l:%M %p")}"
  end

  def set_next_occurrence
    self.schedule_next = schedule.try(:next_occurrence)
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
    list_item_attrs = self.attributes.symbolize_keys.slice(:important, :permanent, :category, :name)
    list_item_attrs.merge!(schedule: self.schedule_in_words)
    list_item_attrs.merge!(countdown: (self.schedule_next.to_f * 1000).round) unless self.schedule.nil?
    ActionCable.server.broadcast "list_item_#{self.id}_channel", list_item: list_item_attrs
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
