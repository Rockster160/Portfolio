# == Schema Information
#
# Table name: agenda_items
#
#  id                 :bigint           not null, primary key
#  color              :string
#  completed_at       :datetime
#  detached_at        :datetime
#  end_at             :datetime
#  kind               :integer          not null
#  location           :string
#  name               :string           not null
#  notes              :text
#  notified_at        :datetime
#  original_start_at  :datetime
#  start_at           :datetime         not null
#  trigger_expression :text
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  agenda_id          :bigint           not null
#  agenda_schedule_id :bigint
#
class AgendaItem < ApplicationRecord
  include Jilable

  KINDS = AgendaSchedule::KINDS
  PHANTOM_ID_RE = /\Ap-(\d+)-(\d{4}-\d{2}-\d{2})\z/
  BARE_STATE_TOKENS = %w[
    incomplete
    complete
    completed
    pending
    overdue
    upcoming
    past
    today
    recurring
    detached
    phantom
    task
    event
    trigger
    tasks
    events
    triggers
  ].freeze

  attr_accessor :phantom

  enum :kind, { task: 0, event: 1, trigger: 2 }

  belongs_to :agenda
  belongs_to :agenda_schedule, optional: true

  validates :name, presence: true
  validates :start_at, presence: true
  validate :end_at_after_start_at
  validate :end_at_required_for_event

  after_update :broadcast_agenda_change!, if: :saved_change_to_agenda_id?
  before_save :clear_notified_at_on_future_reschedule
  after_commit :fire_jil_trigger, on: [:create, :update]
  after_commit :fire_jil_destroy_trigger, on: :destroy

  search_terms(
    :id, :name, :notes, :location,
    kind:       :kind_search,
    timestamp:  :start_at,
    start_at:   :start_at,
    end_at:     :end_at,
    completed:  :completed_search,
    incomplete: :incomplete_search,
    overdue:    :overdue_search,
    upcoming:   :upcoming_search,
    past:       :past_search,
    today:      :today_search,
    recurring:  :recurring_search,
    detached:   :detached_search
  )

  scope :completed,  -> { where.not(completed_at: nil) }
  scope :incomplete, -> { where(completed_at: nil) }
  scope :pending,    -> { incomplete } # back-compat alias
  # Events auto-disappear once end_at passes — overdue applies to tasks
  # and triggers only.
  scope :overdue,    -> { where.not(kind: :event).incomplete.where(start_at: ...Time.current) }
  scope :upcoming,   -> { where(start_at: Time.current..) }
  scope :recurring,  -> { where.not(agenda_schedule_id: nil) }
  scope :detached,   -> { where.not(detached_at: nil) }

  # ---- query-syntax scopes (called by ApplicationRecord#query via search_terms) ----
  scope :kind_search, ->(val) {
    enum_value = kinds[val.to_s.downcase] || kinds[val.to_s.downcase.singularize]
    enum_value.present? ? where(kind: enum_value) : none
  }
  scope :completed_search,  ->(val) { truthy_query?(val) ? completed : incomplete }
  scope :incomplete_search, ->(val) { truthy_query?(val) ? incomplete : completed }
  scope :overdue_search,    ->(val) { truthy_query?(val) ? overdue : where("start_at >= ? OR completed_at IS NOT NULL", Time.current) }
  scope :upcoming_search,   ->(val) { truthy_query?(val) ? upcoming : where(start_at: ...Time.current) }
  scope :past_search,       ->(val) { truthy_query?(val) ? where(start_at: ...Time.current) : where(start_at: Time.current..) }
  scope :today_search,      ->(val) {
    range = Time.current.all_day
    truthy_query?(val) ? where(start_at: range) : where.not(start_at: range)
  }
  scope :recurring_search,  ->(val) { truthy_query?(val) ? recurring : where(agenda_schedule_id: nil) }
  scope :detached_search,   ->(val) { truthy_query?(val) ? detached : where(detached_at: nil) }

  def self.truthy_query?(val)
    val.to_s.match?(/\A(t|true|y|yes|1|on)\z/i) || val.to_s.empty?
  end

  # Expands bare state tokens (BARE_STATE_TOKENS) so the search syntax
  # accepts `kind:task incomplete overdue` instead of requiring the long
  # form `kind:task incomplete:true overdue:true`.
  def self.query(q)
    return all if q.blank?

    expanded = q.split(/\s+/).map { |token|
      next token if token.include?(":") || token.match?(/\A[!-]/)

      stripped = token.downcase
      if BARE_STATE_TOKENS.include?(stripped)
        case stripped
        when "task", "tasks"       then "kind:task"
        when "event", "events"     then "kind:event"
        when "trigger", "triggers" then "kind:trigger"
        else "#{stripped}:true"
        end
      else
        token
      end
    }.join(" ")

    super(expanded)
  end

  delegate :user, to: :agenda

  # Resolves an id (digits) or a phantom_id ("p-{schedule_id}-{date}")
  # against an Agenda. Returns a persisted AgendaItem, an unsaved phantom,
  # or nil.
  def self.locate(id_or_phantom, agenda:)
    str = id_or_phantom.to_s
    if (match = str.match(PHANTOM_ID_RE))
      resolve_phantom(match[1].to_i, Date.parse(match[2]), agenda: agenda)
    else
      agenda.agenda_items.find_by(id: str)
    end
  end

  # Like .locate but scoped to any agenda the user can access (or only
  # editable ones, with `editable: true`). Returns nil if unreachable.
  def self.locate_for_user(id_or_phantom, user, editable: false)
    scope = editable ? user.editable_agendas : user.accessible_agendas
    str = id_or_phantom.to_s
    if (match = str.match(PHANTOM_ID_RE))
      schedule = AgendaSchedule.where(agenda_id: scope.select(:id)).find_by(id: match[1].to_i)
      return nil unless schedule

      resolve_phantom(schedule.id, Date.parse(match[2]), agenda: schedule.agenda)
    else
      AgendaItem.where(agenda_id: scope.select(:id)).find_by(id: str)
    end
  end

  def self.resolve_phantom(schedule_id, date, agenda:)
    schedule = agenda.agenda_schedules.find_by(id: schedule_id)
    return nil if schedule.blank?

    real = schedule.agenda_items
      .where(start_at: agenda.send(:day_range, date))
      .first
    return real if real
    return nil unless schedule.matches?(date)

    schedule.build_phantom(date)
  end

  def completed?
    completed_at.present?
  end

  def detached?
    detached_at.present?
  end

  def recurring?
    agenda_schedule_id.present?
  end

  def phantom?
    !!@phantom
  end

  def display_id
    phantom? ? "p-#{agenda_schedule_id}-#{occurrence_date.iso8601}" : id.to_s
  end

  # Effective color: item override → schedule color → agenda color → default.
  def display_color
    color.presence ||
      agenda_schedule&.display_color ||
      agenda.color.presence ||
      Agenda::DEFAULT_COLOR
  end

  def occurrence_date
    start_at.in_time_zone(user.timezone).to_date
  end

  def visible_on?(date)
    occurrence_date == date
  end

  def crossed_out_at(now: Time.current)
    return completed_at if completed?
    return end_at if event? && end_at.present? && end_at <= now

    nil
  end

  def crossed_out?(now: Time.current)
    crossed_out_at(now: now).present?
  end

  def complete!(at: Time.current)
    update!(completed_at: at)
  end

  def uncomplete!
    update!(completed_at: nil)
  end

  def notified?
    notified_at.present?
  end

  def mark_notified!
    return if notified?

    update!(notified_at: Time.current)
  end

  # Cancels a single materialized occurrence of a recurring item: adds its
  # date to the schedule's excluded_dates so it won't regenerate as a phantom,
  # then destroys this row.
  def cancel_occurrence!
    agenda_schedule&.add_excluded_date!(occurrence_date)
    destroy
  end

  # Parses the trigger expression on a kind=trigger item. The expression is
  # colon-delimited; quoted segments may contain spaces. Examples:
  #   "goodMorning"                       → ["goodMorning", { agenda_item: ... }]
  #   "notify:tone:soft"                  → ["notify", { tone: "soft", agenda_item: ... }]
  #   'alert:"key with spaces":value'     → ["alert", { :"key with spaces" => "value", agenda_item: ... }]
  # Augments the data with a tie-back so listening tasks can see what fired them.
  # We do our own segmenting rather than calling TriggerData.parse directly
  # because TriggerData.parse's gating regex (`\w+(:\w+)+`) rejects quoted
  # segments containing spaces.
  def parsed_trigger
    return [nil, {}] unless trigger?
    return [nil, {}] if trigger_expression.blank?

    segments = self.class.parse_trigger_segments(trigger_expression.to_s.strip)
    return [nil, {}] if segments.blank?

    scope = segments.shift
    raw_data = (
      if segments.empty?
        {}
      else
        segments.reverse.reduce { |value, key| { key.to_sym => value } }
      end
    )
    raw_data = { data: raw_data } unless raw_data.is_a?(::Hash)

    data = raw_data.merge(
      agenda_item: {
        id:                 id,
        agenda_id:          agenda_id,
        name:               name,
        agenda_schedule_id: agenda_schedule_id,
      }.compact,
    )
    [scope, data]
  end

  # Splits a colon-delimited expression preserving quoted segments. A colon
  # inside `"..."` is treated as data, not a separator. Only the OUTER pair of
  # quotes wrapping an entire segment is stripped — inner quotes are preserved
  # so users can write things like `command:Remind me to "add water to plants"`
  # and have Jarvis see the inner quotes verbatim (otherwise Jarvis would
  # parse "add water to plants" as a nested list command).
  def self.parse_trigger_segments(str)
    segments = []
    buf = +""
    in_quote = false

    str.each_char { |c|
      if c == '"'
        in_quote = !in_quote
        buf << c
      elsif c == ":" && !in_quote
        segments << buf
        buf = +""
      else
        buf << c
      end
    }
    segments << buf

    segments.map { |seg|
      stripped = seg.strip
      # Outer quotes wrap the WHOLE segment → strip them. Inner quotes stay.
      if stripped.length >= 2 && stripped.start_with?('"') && stripped.end_with?('"')
        stripped[1..-2]
      else
        stripped
      end
    }.reject(&:empty?)
  end

  # Persist a phantom into a real row, optionally with attribute overrides.
  def materialize!(attrs={})
    return self unless phantom?

    @phantom = false
    assign_attributes(attrs) if attrs.present?
    save!
    self
  end

  def serialize(opts={})
    super({
      only: [
        :id,
        :agenda_id,
        :agenda_schedule_id,
        :kind,
        :name,
        :notes,
        :location,
        :start_at,
        :end_at,
        :completed_at,
        :detached_at,
      ],
    }.merge(opts)).merge(
      id:                 display_id,
      color:              display_color,
      agenda_name:        agenda&.name,
      agenda_color:       agenda&.color,
      agenda_slug:        agenda&.parameterized_name,
      phantom:            phantom?,
      crossed_out:        crossed_out?,
      recurring:          recurring?,
      detached:           detached?,
      trigger_expression: trigger_expression,
      schedule:           agenda_schedule&.serialize_for_edit,
    )
  end

  def jil_serialize(additional={})
    serialize.merge(agenda: { id: agenda.id, name: agenda.name }).merge(additional)
  end

  private

  # Emits a Jil trigger so user tasks listening on `agenda_item` (e.g. the
  # dashboard re-broadcast trigger) can react to lifecycle changes. Mirrors
  # the Task / ActionEvent pattern — passes the record with execution attrs
  # rather than a serialized hash so Ruby's kwargs separation doesn't fire.
  def fire_jil_trigger
    action = saved_change_to_id? ? :created : :updated
    ::Jil.trigger(user, :agenda_item, with_jil_attrs(action: action))
  end

  def fire_jil_destroy_trigger
    ::Jil.trigger(user, :agenda_item, with_jil_attrs(action: :destroyed))
  end

  # Fan out a combined broadcast for both the old and new agendas — each
  # recipient only sees agendas they can access (no cross-leak), users in
  # both get one refresh instead of two.
  def broadcast_agenda_change!
    old_id = saved_changes[:agenda_id].first
    old_agenda = Agenda.find_by(id: old_id)
    Agenda.broadcast_changes!([old_agenda, agenda].compact)
  end

  def clear_notified_at_on_future_reschedule
    return unless will_save_change_to_start_at?
    return if notified_at.nil?
    return if start_at.nil? || start_at <= Time.current

    self.notified_at = nil
  end

  def end_at_after_start_at
    return if end_at.blank? || start_at.blank?

    errors.add(:end_at, "must be after start_at") if end_at <= start_at
  end

  def end_at_required_for_event
    errors.add(:end_at, "is required for events") if event? && end_at.blank?
  end
end
