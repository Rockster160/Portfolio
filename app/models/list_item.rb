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
#  schedule       :string
#  schedule_next  :datetime
#  sort_order     :integer
#  timezone       :integer
#  created_at     :datetime
#  updated_at     :datetime
#  list_id        :integer
#

class ListItem < ApplicationRecord
  attr_accessor :do_not_broadcast
  belongs_to :list

  before_save :set_sort_order, :normalize_values
  after_commit :broadcast_commit

  validates :name, presence: true

  default_scope { where(deleted_at: nil) }

  scope :ordered, -> { order("list_items.sort_order DESC NULLS LAST") }
  scope :important, -> { where(important: true) }
  scope :unimportant, -> { where.not(important: true) }

  def self.by_formatted_name(name)
    find_by(formatted_name: name.to_s.downcase.gsub(/[^a-z0-9]/i, ""))
  end

  def self.by_name_then_update(params)
    old_item = by_data(params)

    if old_item.present?
      old_item.update(params.merge(deleted_at: nil, sort_order: nil))
      old_item
    else
      create(params)
    end
  end

  def self.by_data(params)
    if params.is_a?(Hash) || params.is_a?(ActionController::Parameters)
      with_deleted.find_by(id: params[:id]) || with_deleted.by_formatted_name(params[:name])
    else
      with_deleted.by_formatted_name(name: params.to_s)
    end
  end

  def self.add(item_name)
    old_item = by_data(item_name)

    if old_item.present?
      old_item.update({ name: item_name }.merge(deleted_at: nil, sort_order: nil))
      old_item
    else
      create(name: item_name)
    end
  end

  def self.remove(item_name)
    old_item = by_data(item_name)

    old_item&.soft_destroy
  end

  def self.toggle(item_name)
    old_item = by_data(item_name)

    if old_item.present? && !old_item.deleted?
      old_item&.soft_destroy
    elsif old_item.present?
      old_item.update({ name: item_name }.merge(deleted_at: nil, sort_order: nil))
      old_item
    else
      create(name: item_name)
    end
  end

  def self.with_deleted
    unscope(where: :deleted_at)
  end

  def deleted?
    deleted_at?
  end

  def soft_destroy
    update(deleted_at: Time.current)
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
    minute = schedule_params["minute"].to_i
    repeat_type = schedule_params["type"].to_sym if schedule_params["type"].in?(["minutely", "hourly", "daily", "weekly", "monthly"])
    return if repeat_type.nil?

    full_timezone = "#{timezone.positive? ? '+' : '-'}#{timezone.abs.to_s.rjust(4, '0')}"
    schedule_start = Time.parse("#{hour}:#{minute} #{meridian} #{full_timezone}")
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
    super(new_schedule.to_yaml)
    set_next_occurrence
  end

  def schedule
    return if super.nil?
    @schedule ||= IceCube::Schedule.from_yaml(super) rescue nil
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
    "#{words} at #{schedule.start_time.strftime("%-l:%M %p %Z")}"
  end

  def set_next_occurrence
    self.schedule_next = schedule.try(:next_occurrence)
  end

  def options
    {
      important: "When set, this item will automatically appear at the top of the list regardless of the sort order.",
      permanent: "When set, this item will not be removed from list when checking it. Instead, it will appear toggled/selected on your page, but when reloading the page the item will still be present. This also prevents the item from being removed on other user's pages that are sharing the list.  (Does not work if a schedule is set.)"
    }
  end

  private

  def set_sort_order
    self.sort_order ||= list.list_items.with_deleted.maximum(:sort_order).to_i + 1
  end

  def normalize_values
    self.formatted_name = name.downcase.gsub(/[^a-z0-9]/i, "")
    self.category = self.category.squish.titleize.presence if self.category
    self.permanent = false if self.schedule.present?
    true
  end

  def broadcast_commit
    return if do_not_broadcast

    ActionCable.server.broadcast "list_#{self.list_id}_json_channel", { list_data: list.serialize, timestamp: Time.current.to_i }

    list_item_attrs = self.attributes.symbolize_keys.slice(:important, :permanent, :category, :name)
    list_item_attrs.merge!(schedule: self.schedule_in_words)
    list_item_attrs.merge!(countdown: (self.schedule_next.to_f * 1000).round) unless self.schedule.nil?
    ActionCable.server.broadcast "list_item_#{self.id}_channel", { list_item: list_item_attrs }

    rendered_message = ListsController.render template: "list_items/index", locals: { list: self.list }, layout: false
    ActionCable.server.broadcast "list_#{self.list_id}_html_channel", { list_html: rendered_message, timestamp: Time.current.to_i }

    JarvisTriggerWorker.perform_async(:list.to_s, { input_vars: { "List Data": list.serialize } }.to_json, { user: list.users.ids }.to_json)
  end

end
