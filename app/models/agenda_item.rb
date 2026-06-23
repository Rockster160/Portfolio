# == Schema Information
#
# Table name: agenda_items
#
#  id                   :bigint           not null, primary key
#  all_day              :boolean          default(FALSE), not null
#  arrive_early_minutes :integer          default(0), not null
#  cancelled_at         :datetime
#  color                :string
#  completed_at         :datetime
#  detached_at          :datetime
#  end_at               :datetime
#  ended_fired_at       :datetime
#  external_etag        :text
#  external_uid         :text
#  external_updated_at  :datetime
#  fired_at             :datetime
#  kind                 :integer          not null
#  local_color          :string
#  locally_modified_at  :datetime
#  location             :string
#  metadata             :jsonb            not null
#  name                 :string           not null
#  notes                :text
#  notified_at          :datetime
#  original_start_at    :datetime
#  start_at             :datetime         not null
#  status               :integer          default("confirmed"), not null
#  trigger_expression   :text
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  agenda_id            :bigint           not null
#  agenda_schedule_id   :bigint
#  client_mutation_id   :string
#
class AgendaItem < ApplicationRecord
  include Jilable

  KINDS = AgendaSchedule::KINDS
  PHANTOM_ID_RE = /\Ap-(\d+)-(\d{4}-\d{2}-\d{2})\z/

  attr_accessor :phantom

  enum :kind, { task: 0, event: 1, trigger: 2 }
  # Mirrors Google's event status vocabulary. `confirmed` is the default
  # everywhere; `tentative` surfaces visually + filters; `cancelled` hides
  # the row from item queries (kept as a soft-delete tombstone so a sync
  # can restore the occurrence if the user un-cancels in Google).
  enum :status, { confirmed: 0, tentative: 1, cancelled: 2 }, default: :confirmed

  belongs_to :agenda
  belongs_to :agenda_schedule, optional: true
  # Derived ScheduledTriggers — automations whose execute_at is computed
  # from this item's start_at. The FK has `ON DELETE CASCADE` so source
  # destroys clean up automatically at the DB layer; the Rails-level
  # `dependent: :destroy` is here as a safety net for code paths that
  # bypass the cascade (e.g. dependent destroys from above).
  has_many :derived_triggers, class_name: "ScheduledTrigger",
                              foreign_key: :source_item_id,
                              dependent: :destroy,
                              inverse_of: :source_item

  validates :name, presence: true
  validates :start_at, presence: true
  validate :end_at_after_start_at
  validate :end_at_required_for_event

  before_save :clear_notified_at_on_future_reschedule
  after_update :broadcast_agenda_change!, if: :saved_change_to_agenda_id?
  after_update_commit :propagate_start_at_to_derived_triggers, if: :saved_change_to_start_at?
  after_commit :fire_jil_trigger, on: [:create, :update]
  after_commit :fire_jil_destroy_trigger, on: :destroy
  after_commit :enqueue_travel_chain_sync, on: [:create, :update, :destroy]

  # State filters are mandatory `is:<state>` markers (or the `kind:` filter for
  # type). Bare words like "upcoming" or "today" are treated as ordinary text
  # search across the indexed columns so they don't silently hijack a user's
  # search for an item whose name happens to contain one of those words.
  search_terms(
    :id, :name, :notes, :location,
    kind:      :kind_search,
    is:        :is_search,
    timestamp: :start_at,
    start_at:  :start_at,
    end_at:    :end_at
  )

  scope :completed,     -> { where.not(completed_at: nil) }
  scope :incomplete,    -> { where(completed_at: nil) }
  scope :pending,       -> { incomplete } # back-compat alias
  scope :not_cancelled, -> { where.not(status: :cancelled) }
  # Events auto-disappear once end_at passes — overdue applies to tasks
  # and triggers only. `upcoming`/`past` are kind-aware so events stay
  # "upcoming" while in progress (end_at >= now); tasks/triggers flip to
  # past at start_at because they have no duration.
  scope :overdue,    -> { where.not(kind: :event).incomplete.where(start_at: ...Time.current) }
  scope :upcoming,   -> {
    where(
      "(kind = :event AND COALESCE(end_at, start_at) >= :now) OR (kind <> :event AND start_at >= :now)",
      event: kinds[:event],
      now:   Time.current,
    )
  }
  scope :past, -> {
    where(
      "(kind = :event AND COALESCE(end_at, start_at) < :now) OR (kind <> :event AND start_at < :now)",
      event: kinds[:event],
      now:   Time.current,
    )
  }
  scope :today,      -> { where(start_at: Time.current.all_day) }
  scope :recurring,  -> { where.not(agenda_schedule_id: nil) }
  scope :detached,   -> { where.not(detached_at: nil) }

  # ---- query-syntax scopes (called by ApplicationRecord#query via search_terms) ----
  scope :kind_search, ->(val) {
    enum_value = kinds[val.to_s.downcase] || kinds[val.to_s.downcase.singularize]
    enum_value.present? ? where(kind: enum_value) : none
  }
  # `is:<state>` — single dispatch for all state filters. `is:phantom` returns
  # none because phantoms aren't persisted; Agenda#search inspects the query
  # for `is:phantom` separately to include phantom recurring occurrences.
  scope :is_search, ->(val) {
    case val.to_s.downcase
    when "upcoming"              then upcoming
    when "past"                  then past
    when "today"                 then today
    when "recurring"             then recurring
    when "completed", "complete" then completed
    when "incomplete", "pending" then incomplete
    when "overdue"               then overdue
    when "detached"              then detached
    when "phantom"               then none
    when "task", "tasks"         then where(kind: :task)
    when "event", "events"       then where(kind: :event)
    when "trigger", "triggers"   then where(kind: :trigger)
    else none
    end
  }

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

  # Effective color resolution, highest priority first:
  #   1. local_color — user's color override (stays local; never sent to
  #      Google on a synced item)
  #   2. color       — for Google items: Google's per-event colorId hex.
  #                    For user items: the user's per-item choice.
  #   3. schedule    — recurring item inherits from its master
  #   4. agenda      — the agenda's color
  #   5. default     — global blue
  def display_color
    local_color.presence ||
      color.presence ||
      agenda_schedule&.display_color ||
      agenda.color.presence ||
      Agenda::DEFAULT_COLOR
  end

  def occurrence_date
    start_at.in_time_zone(user.timezone).to_date
  end

  # End date of the visible span. For all-day events, Google's `end.date`
  # is exclusive (May 27→May 28 = single day) — we mirror that here by
  # subtracting one second when the row is marked all_day, so
  # `start_date..end_date` is the inclusive range the UI shows on.
  def end_date
    finish = (end_at || start_at).in_time_zone(user.timezone)
    finish -= 1.second if all_day? && end_at.present? && end_at > start_at
    finish.to_date
  end

  # True if this item should render on `date`. Single-day events match the
  # start; multi-day all-day events show on every day they span.
  def visible_on?(date)
    return occurrence_date == date unless all_day?

    (occurrence_date..end_date).cover?(date)
  end

  # An item is crossed out in the UI when:
  #   * The user marked it completed.
  #   * It's an event whose end has passed — events are time-bounded.
  #   * It's a trigger whose firing time has passed.
  # Drives the `.crossed-out` CSS class and the hide-completed filter.
  #
  # Crossed-out ≠ checked. The checkbox renders based on `completed?` only
  # (manual user action); time-passed events / triggers strike through
  # visually but the checkbox stays unchecked until the user clicks it.
  # Tasks NEVER auto-cross-out — they wait on the checkbox.
  def crossed_out_at(now: Time.current)
    return completed_at if completed?
    return end_at if event? && end_at.present? && end_at <= now
    return start_at if trigger? && start_at.present? && start_at <= now

    nil
  end

  def crossed_out?(now: Time.current)
    crossed_out_at(now: now).present?
  end

  # Distinct from `completed?` — `fired?` means the firing worker ran the
  # trigger, but the user-facing checkbox stays unchecked. The user can
  # still mark complete (post-fire personal tracking) or pre-mark complete
  # to skip the firing entirely. Stored on AgendaItem because phantoms
  # don't need it (phantoms haven't been materialized yet).
  def fired?
    fired_at.present?
  end

  # Google attendee metadata, hydrated from sync.rb into the JSONB
  # `metadata` column. `attendees` is an array of hashes with stringified
  # keys (default for JSONB reads); `self_response` is the connected
  # user's responseStatus on the event (accepted/tentative/declined/
  # needsAction, or nil when not an invite).
  def attendees
    Array(metadata["attendees"])
  end

  def organizer
    metadata["organizer"].presence
  end

  def self_response
    metadata["self_response"].presence
  end

  def invite?
    attendees.any?
  end

  def needs_response?
    self_response == "needsAction"
  end

  def declined?
    self_response == "declined"
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

  # Cancels a single materialized occurrence of a recurring item: adds
  # its date to the schedule's excluded_dates so it won't regenerate as
  # a phantom, then marks the row cancelled (NOT destroyed) so the
  # historical record + audit trail survives. Views filter cancelled
  # rows out via the `not_cancelled` scope.
  def cancel_occurrence!
    agenda_schedule&.add_excluded_date!(occurrence_date)
    update!(status: :cancelled, cancelled_at: Time.current)
  end

  # Parses the trigger expression on a kind=trigger item. The expression is
  # colon-delimited; quoted segments may contain spaces. Examples:
  #   "goodMorning"                       → ["goodMorning", { agenda_item: ... }]
  #   "notify:tone:soft"                  → ["notify", { tone: "soft", agenda_item: ... }]
  #   'alert:"key with spaces":value'     → ["alert", { :"key with spaces" => "value", agenda_item: ... }]
  # Augments the data with a tie-back so listening tasks can see what fired them.
  # We do our own segmenting here to preserve inner quotes verbatim inside a
  # segment (so `command:Remind me to "add water to plants"` keeps the nested
  # quotes for Jarvis to see). Tokenizing::TriggerData.parse handles quoted
  # segments uniformly but unwraps inner quotes the same as outer.
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

  # All time-shaped attributes serialize as integer epoch seconds (UTC).
  # The server never picks a display timezone — the FE renders in the
  # viewing browser's local zone, and write paths receive the same shape
  # back, so an event the user enters as "4pm browser-local" round-trips
  # without any cross-zone interpretation.
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
        :arrive_early_minutes,
        :all_day,
        :metadata,
      ],
    }.merge(opts)).merge(
      id:                 display_id,
      status:             status,
      color:              display_color,
      agenda_name:        agenda&.name,
      agenda_color:       agenda&.color,
      agenda_slug:        agenda&.parameterized_name,
      phantom:            phantom?,
      crossed_out:        crossed_out?,
      recurring:          recurring?,
      detached:           detached?,
      trigger_expression: trigger_expression,
      start_at:           start_at&.to_i,
      end_at:             end_at&.to_i,
      original_start_at:  original_start_at&.to_i,
      completed_at:       completed_at&.to_i,
      fired_at:           fired_at&.to_i,
      detached_at:        detached_at&.to_i,
      cancelled_at:       cancelled_at&.to_i,
      updated_at:         updated_at&.to_i,
      schedule:           agenda_schedule&.serialize_for_edit,
      attendees:          attendees,
      organizer:          organizer,
      self_response:      self_response,
      needs_response:     needs_response?,
      declined:           declined?,
      client_mutation_id: client_mutation_id,
      presentation_attrs: presentation_attrs,
    )
  end

  def jil_serialize(additional={})
    serialize.merge(agenda: { id: agenda.id, name: agenda.name }).merge(additional)
  end

  # Canonical data-* payload for an item. Used in two contexts:
  #   * `_data_attrs.html.erb` iterates this hash to emit attributes for
  #     the agenda list (day/week) + calendar (cal_month/cal_week) views.
  #   * `AgendaItem#serialize` includes it under `presentation_attrs` so
  #     `seed_hydrator.js` builds the same attributes from the JS store
  #     without a parallel hardcoded attribute list.
  #
  # Keys are the kebab-case stems (no `data-` prefix). View-context flags
  # like `data-readonly` and the cal_month `data-all-day` override are
  # applied by the partial / hydrator, not here — this hash is pure item
  # data, no caller context.
  def presentation_attrs
    travel = metadata.is_a?(Hash) ? (metadata["travel"] || {}) : {}
    {
      "item-id"               => display_id,
      "item-url"              => "/agenda_items/#{display_id}",
      "phantom"               => phantom?,
      "recurring"             => recurring?,
      "agenda-schedule-id"    => agenda_schedule_id,
      "detached"              => detached?,
      "kind"                  => kind,
      "color"                 => display_color,
      "agenda-id"             => agenda_id,
      "agenda-name"           => agenda&.name,
      "agenda-color"          => agenda&.color,
      "agenda-source"         => agenda&.source,
      "all-day"               => all_day?,
      # Inclusive last-day midnight, anchored in the user's timezone — NOT
      # `to_time` (which lands in Rails' Time.zone, defaulting to UTC) and
      # NOT `end_at.to_i` (which is the exclusive next-day-midnight per
      # Google convention). Using user.timezone keeps the epoch aligned
      # with the day the browser will format it into for any user whose
      # browser shares their tz. Mirrors `optimistic_item.js` (`endAt -
      # 86400` for all-day) and `recurrence.js` for phantom parity.
      "end-date"              => end_date&.in_time_zone(user.timezone)&.beginning_of_day&.to_i,
      "start-at"              => start_at&.to_i,
      "end-at"                => end_at&.to_i,
      "name"                  => name,
      "notes"                 => notes,
      "location"              => location,
      "resolved-address"      => travel["location_address"],
      "arrive-early-minutes"  => arrive_early_minutes.to_i,
      "travel-minutes"        => travel["travel_minutes"].to_i,
      "travel-from-kind"      => travel["travel_from_kind"],
      "travel-from"           => travel["travel_from"],
      "chain-predecessor-id"  => travel["chain_predecessor_id"],
      "chain-successor-id"    => travel["chain_successor_id"],
      "chain-prev-end-epoch"  => travel["chain_prev_end_at"],
      "leave-at-epoch"        => travel["leave_at"],
      "post-travel-to"        => travel["post_travel_to"],
      "post-travel-minutes"   => travel["post_travel_minutes"].to_i,
      "post-arrive-at-epoch"  => travel["post_arrive_at"],
      "trigger-expression"    => trigger_expression,
      "schedule"              => agenda_schedule&.serialize_for_edit&.to_json,
      "attendees"             => attendees.to_json,
      "organizer"             => organizer.to_json,
      "self-response"         => self_response,
    }
  end

  private

  # Emits a Jil trigger so user tasks listening on `agenda_item` (e.g. the
  # dashboard re-broadcast trigger) can react to lifecycle changes. Mirrors
  # the Task / ActionEvent pattern — passes the record with execution attrs
  # rather than a serialized hash so Ruby's kwargs separation doesn't fire.
  #
  # Trigger-kind items are skipped: they fire their OWN scope via
  # FireDueAgendaTriggersWorker (or Jarvis for `command:` form), and the
  # auto-complete stamp that follows that fire would otherwise emit a
  # second, noisier :agenda_item event for the same row.
  def fire_jil_trigger
    return if trigger?
    # Suppressed mid-sync: GoogleCalendar::Sync fans out one trigger + one
    # broadcast at the tail of a sync rather than per-row. Avoids
    # trigger-storms on initial backfill of a busy calendar.
    return if Thread.current[::GoogleCalendar::Sync::SUPPRESS_KEY]
    # Metadata is Jil-derived (travel time, etc.) — writing it shouldn't
    # refire the agenda_item trigger and re-run the same task.
    return if metadata_only_change?

    action = saved_change_to_id? ? :created : :updated
    ::Jil.trigger(user, :agenda_item, with_jil_attrs(action: action))
  end

  # True when this commit reflects either (a) no real attribute change at
  # all — Rails still fires after_commit on no-op `update!` calls — or
  # (b) a Jil-side metadata write. Either way the :agenda_item trigger
  # would only re-run the same listener with stale-or-identical data;
  # short-circuit instead so the Jil-side `evt.update!` doesn't recurse
  # back into its own task.
  def metadata_only_change?
    return true if saved_changes.empty?
    return true if (saved_changes.keys - ["metadata", "updated_at"]).empty? && saved_change_to_metadata?

    false
  end

  def fire_jil_destroy_trigger
    return if trigger?
    return if Thread.current[::GoogleCalendar::Sync::SUPPRESS_KEY]

    ::Jil.trigger(user, :agenda_item, with_jil_attrs(action: :destroyed))
  end

  # Enqueue the travel-chain sync only when something the chain actually
  # cares about has changed — every other update (notes prose, attendees,
  # color, completion) should be a no-op so we don't burn worker capacity
  # or cache misses. Guards layered in order of cheapness.
  CHAIN_RELEVANT_COLUMNS = %w[start_at end_at location arrive_early_minutes kind all_day].freeze

  def enqueue_travel_chain_sync
    return if Thread.current[::GoogleCalendar::Sync::SUPPRESS_KEY]
    return unless chain_sync_relevant?

    dates = chain_sync_dates
    return if dates.empty?

    dates.each do |date|
      ::AgendaTravelChainSyncWorker.perform_async(user.id, date.iso8601)
    end
  end

  def chain_sync_relevant?
    return false unless user

    # Destroyed event: only matters if it was an event and had a location at
    # destroy-time. metadata_only_change? doesn't apply to destroy.
    if destroyed?
      return event? && location.present?
    end

    # Metadata-only writes are how the chain sync itself updates events —
    # never re-enqueue on those, otherwise the worker recursively re-fires.
    return false if metadata_only_change?

    # Kind must currently BE event, or have just become one. all_day events
    # are excluded — they don't get travel chains.
    return false unless event_after_save?
    return false if all_day? && !saved_change_to_all_day?

    return true if (saved_changes.keys & CHAIN_RELEVANT_COLUMNS).any?
    return true if overrides_changed?

    false
  end

  def event_after_save?
    return true if event?

    saved_change_to_kind? && saved_changes["kind"].last == self.class.kinds[:event]
  end

  def overrides_changed?
    return false unless saved_change_to_notes?

    old_n, new_n = saved_changes["notes"]
    ::AgendaTravelChain::OverrideParser.changed?(old_n, new_n)
  end

  # Compute the affected perceived-day(s). For a moved event we want both the
  # old day and the new day so the previous day's chain rebuilds without the
  # event (and the new day's chain rebuilds with it).
  def chain_sync_dates
    out = []
    out << perceived_date_for(start_at) if start_at.present?
    if saved_change_to_start_at? && saved_changes["start_at"].first.present?
      out << perceived_date_for(saved_changes["start_at"].first)
    end
    out.compact.uniq
  end

  def perceived_date_for(timestamp)
    return nil if timestamp.blank?

    zone = ::ActiveSupport::TimeZone[user.timezone] || ::Time.zone
    zone.at(timestamp.to_i).to_date
  end

  # When this item's start_at moves, every derived ScheduledTrigger's
  # execute_at moves with it (source.start_at + offset_seconds). Already-
  # started rows are skipped — their automation has already begun. Only
  # the not-yet-started rows get rescheduled in Sidekiq via
  # Jil::Schedule.update, which cancels the old job and enqueues the new.
  def propagate_start_at_to_derived_triggers
    return if start_at.blank?

    derived_triggers.not_started.find_each do |sched|
      new_execute_at = start_at + sched.offset_seconds.to_i
      sched.update_columns(execute_at: new_execute_at)
      ::Jil::Schedule.update(sched)
    end
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
