# == Schema Information
#
# Table name: agendas
#
#  id                 :bigint           not null, primary key
#  color              :string
#  name               :string           not null
#  parameterized_name :string           not null
#  sort_order         :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  user_id            :bigint           not null
#
class Agenda < ApplicationRecord
  include Jilable, Orderable

  orderable_by(sort_order: :asc)
  orderable_scope(:user_agendas)

  DEFAULT_COLOR = "#0160FF".freeze

  belongs_to :user
  has_many :agenda_schedules, dependent: :destroy
  has_many :agenda_items, dependent: :destroy
  has_many :agenda_shares, dependent: :destroy
  has_many :shared_users, through: :agenda_shares, source: :user
  has_many :editor_shares, -> { where(permission: :editor) }, class_name: "AgendaShare"
  has_many :editor_users, through: :editor_shares, source: :user
  has_many :agenda_notification_settings, dependent: :destroy

  validates :name, presence: true
  validates :parameterized_name, presence: true, uniqueness: { scope: :user_id }

  before_validation :set_parameterized_name
  before_validation :set_color, on: :create

  scope :by_param, ->(name) { where(parameterized_name: name.to_s.parameterize) }

  def access_users
    User.where(id: ([user_id] + shared_users.pluck(:id)).uniq)
  end

  def editable_by?(other_user)
    return false if other_user.blank?
    return true if user_id == other_user.id

    agenda_shares.editor.exists?(user_id: other_user.id)
  end

  def visible_to?(other_user)
    return false if other_user.blank?
    return true if user_id == other_user.id

    agenda_shares.exists?(user_id: other_user.id)
  end

  delegate :agendas, to: :user, prefix: true

  def to_param
    parameterized_name
  end

  # Two SQL queries regardless of range size — one for materialized rows,
  # one for active schedules. Phantom occurrences are built in-memory.
  def items_for_range(from, to)
    from_date = from.to_date
    to_date = to.to_date

    range = range_for_dates(from_date, to_date)
    real_items = agenda_items.where(start_at: range).order(:start_at).to_a
    schedules = agenda_schedules.active_between(from_date, to_date).to_a

    materialized_keys = real_items.each_with_object(Set.new) { |item, set|
      next if item.agenda_schedule_id.blank?
      # Detached rows kept their schedule_id for history, but they're
      # standalone — they must NOT suppress the parent schedule's phantom
      # on whatever date they currently sit on (e.g. an item moved onto a
      # day that already has a recurring occurrence).
      next if item.detached_at.present?

      set << [item.agenda_schedule_id, item.occurrence_date]
    }

    phantoms = schedules.flat_map { |schedule|
      (from_date..to_date).filter_map { |date|
        next unless schedule.matches?(date)
        next if materialized_keys.include?([schedule.id, date])

        schedule.build_phantom(date)
      }
    }

    (real_items + phantoms).sort_by(&:start_at)
  end

  def items_for(date)
    items_for_range(date, date)
  end

  def visible_items_for(date)
    items_for(date).select { |item| item.visible_on?(date) }
  end

  def carry_over_items
    today_start = Date.current.in_time_zone(user.timezone).beginning_of_day
    agenda_items
      .where(kind: :task)
      .where(start_at: ...today_start)
      .where("completed_at IS NULL OR completed_at >= ?", today_start)
      .order(:start_at)
  end

  def serialize_for_monitor(date: Date.current)
    {
      agenda_id:  id,
      name:       name,
      color:      color,
      date:       date.to_s,
      today:      visible_items_for(date).map(&:serialize),
      tomorrow:   visible_items_for(date + 1).map(&:serialize),
      carry_over: carry_over_items.map(&:serialize),
    }
  end

  def broadcast!
    self.class.broadcast_changes!([self])
  end

  # Fans out a change signal: each recipient's payload includes only the
  # agendas they can access, so an item move between agendas never leaks
  # the foreign agenda's metadata to users who can't see it.
  def self.broadcast_changes!(agendas)
    agendas = Array(agendas).compact.uniq
    return if agendas.empty?

    per_user = Hash.new { |h, k| h[k] = [] }
    agendas.each do |a|
      a.access_users.find_each { |u| per_user[u] << a }
    end

    per_user.each do |user, accessible|
      MonitorChannel.broadcast_to(user, {
        id:        :agenda,
        channel:   :agenda,
        timestamp: Time.current.to_i,
        data:      {
          changed: accessible.map { |a| { agenda_id: a.id, slug: a.parameterized_name } },
        },
      })
    end
  end

  private

  def set_parameterized_name
    self.parameterized_name = name.to_s.parameterize if name.present?
  end

  def set_color
    self.color ||= DEFAULT_COLOR
  end

  def day_range(date)
    range_for_dates(date.to_date, date.to_date)
  end

  def range_for_dates(from, to)
    zone = ActiveSupport::TimeZone[user.timezone] || Time.zone
    zone.local(from.year, from.month, from.day).beginning_of_day..zone.local(to.year, to.month, to.day).end_of_day
  end
end
