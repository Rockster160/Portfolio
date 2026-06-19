# == Schema Information
#
# Table name: agendas
#
#  id                 :bigint           not null, primary key
#  color              :string
#  name               :string           not null
#  parameterized_name :string           not null
#  sort_order         :integer
#  source             :integer          default("user"), not null
#  sync_reason        :string
#  sync_token         :text
#  synced_at          :datetime
#  watch_expires_at   :datetime
#  watch_failed_at    :datetime
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  external_id        :text
#  google_account_id  :bigint
#  user_id            :bigint           not null
#  watch_channel_id   :text
#  watch_resource_id  :text
#
class Agenda < ApplicationRecord
  include Jilable, Orderable

  orderable_by(sort_order: :asc)
  orderable_scope(:user_agendas)

  DEFAULT_COLOR = "#0160FF".freeze

  # Re-subscribe a Google push channel this many days before it expires.
  # Google caps channel TTL at ~7 days; we leave a buffer so a worker hiccup
  # doesn't drop us into webhook-less territory.
  WATCH_RENEWAL_LEAD = 1.day

  # When Google denies events.watch for an agenda (holiday/shared calendars
  # that don't support push), back off this long before retrying.
  WATCH_FAILURE_COOLDOWN = 1.day

  enum :source, { user: 0, google: 1 }, default: :user

  belongs_to :user
  # External-source agendas point at the GoogleAccount that owns the
  # upstream calendar. User-source agendas leave it nil.
  belongs_to :google_account, optional: true
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
  # Prune our id out of every user's hidden_agenda_ids preference so the
  # column doesn't grow stale dangling references to deleted agendas.
  after_destroy :prune_from_user_preferences!

  scope :by_param, ->(name) { where(parameterized_name: name.to_s.parameterize) }

  def access_users
    User.where(id: ([user_id] + shared_users.pluck(:id)).uniq)
  end

  # Can add/edit/complete items + schedules. Owners are implicitly editors.
  def editable_by?(other_user)
    return false if other_user.blank?
    return true if owned_by?(other_user)

    agenda_shares.exists?(user_id: other_user.id, permission: [:editor, :owner])
  end

  # Can rename/recolor the agenda itself, manage shares, destroy. The
  # primary user_id is always an owner; additional shared users with the
  # :owner permission qualify too.
  def owned_by?(other_user)
    return false if other_user.blank?
    return true if user_id == other_user.id

    agenda_shares.exists?(user_id: other_user.id, permission: :owner)
  end

  # External agendas are owned by an upstream system (Google Calendar).
  # User edits to items in these agendas mirror upstream via the controller
  # (events.patch / events.delete / events.insert) — the sync pipeline pulls
  # changes in the other direction. The agenda's own `source` cannot be
  # flipped after creation, and the agenda itself is destroyed only via the
  # Disconnect flow (not the agenda#destroy endpoint).
  def managed_externally?
    !user?
  end

  scope :externally_managed, -> { where.not(source: sources[:user]) }
  scope :due_for_watch_renewal, ->(now: Time.current) {
    externally_managed
      .where(watch_expires_at: ..(now + WATCH_RENEWAL_LEAD))
      .where("watch_failed_at IS NULL OR watch_failed_at < ?", now - WATCH_FAILURE_COOLDOWN)
  }
  scope :needing_reauth, -> {
    externally_managed.joins(:google_account).where.not(google_accounts: { reauth_required_at: nil })
  }
  # Either: the account was soft-disconnected (tokens cleared, picker needs
  # a reauth click) OR Google has flagged the tokens dead. Either way the
  # /agenda/manage banner needs to surface a reconnect CTA — the bare
  # `needing_reauth` scope missed the soft-disconnected case and stranded
  # users with no visible explanation.
  scope :needing_attention, -> {
    externally_managed.joins(:google_account).where(
      "google_accounts.reauth_required_at IS NOT NULL OR google_accounts.disconnected_at IS NOT NULL",
    )
  }

  # Skip watch attempts if we already have a live channel OR Google recently
  # told us this calendar doesn't support push.
  def needs_watch?
    return false if watch_channel_id.present?
    return false if watch_failed_at.present? && watch_failed_at > WATCH_FAILURE_COOLDOWN.ago

    true
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
  #
  # The materialized-item query matches on *overlap*: an item is in-window
  # if its (start_at..end_at) range intersects (from..to). This is what
  # lets multi-day all-day events appear on each day they cover, not just
  # the start date.
  def items_for_range(from, to)
    self.class.items_for_range_in([id], from, to, reference_user: user, preloaded_agendas: [self])
  end

  # Bulk variant — collects items + phantoms across many agendas in a
  # constant number of queries regardless of how many agendas are passed.
  # Called by User#agenda_items_for_range so the aggregated agenda views
  # (day / week / calendar) don't iterate per-agenda.
  #
  # `preloaded_agendas` lets the caller hand in agenda objects (with
  # `.user` already loaded) so the phantom-building loop's `user_zone`
  # call doesn't fire `schedule.agenda → agenda.user` per row.
  def self.items_for_range_in(agenda_ids, from, to, reference_user:, preloaded_agendas: nil)
    ids = Array(agenda_ids).compact
    return [] if ids.empty?

    from_date = from.to_date
    to_date = to.to_date
    zone = ::ActiveSupport::TimeZone[reference_user.timezone] || ::Time.zone
    range_start = zone.local(from_date.year, from_date.month, from_date.day).beginning_of_day
    range_end   = zone.local(to_date.year,   to_date.month,   to_date.day).end_of_day

    real_items = AgendaItem
      .where(agenda_id: ids)
      .not_cancelled
      .where("start_at <= ? AND COALESCE(end_at, start_at) >= ?", range_end, range_start)
      .order(:start_at)
      .to_a
    schedules = AgendaSchedule
      .where(agenda_id: ids)
      .active_between(from_date, to_date)
      .to_a

    # Wire the parent agenda back onto every fetched item + schedule so
    # consumers iterating `.agenda` / `.user` don't N+1.
    if preloaded_agendas.present?
      by_id = preloaded_agendas.index_by(&:id)
      real_items.each { |i| i.association(:agenda).target = by_id[i.agenda_id] if by_id.key?(i.agenda_id) }
      schedules.each  { |s| s.association(:agenda).target = by_id[s.agenda_id] if by_id.key?(s.agenda_id) }
    end

    materialized_keys = real_items.each_with_object(Set.new) { |item, set|
      next if item.agenda_schedule_id.blank?
      # Detached rows kept their schedule_id for history, but they're
      # standalone on the date they currently sit on (e.g. an item moved
      # onto a day that already has a recurring occurrence — both should
      # render). HOWEVER, the override IS the canonical replacement for
      # its `original_start_at` occurrence, so we still must suppress the
      # phantom on the ORIGINAL date — otherwise a Google-synced override
      # leaves the rule's untouched occurrence ghosting at the source date
      # alongside the relocated override.
      if item.detached_at.present?
        if item.original_start_at.present?
          original_date = item.original_start_at.in_time_zone(reference_user.timezone).to_date
          set << [item.agenda_schedule_id, original_date]
        end
        next
      end

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

  def broadcast!(destroyed_item_ids: [])
    self.class.broadcast_changes!([self], destroyed_item_ids: destroyed_item_ids)
  end

  # Fans out a change signal: each recipient's payload includes only the
  # agendas they can access, so an item move between agendas never leaks
  # the foreign agenda's metadata to users who can't see it.
  #
  # `destroyed_item_ids` carries display_ids of items that were HARD
  # destroyed (not status-cancelled) since the last broadcast — the
  # delta endpoint is upsert-only and can't return rows that no longer
  # exist, so the FE store would otherwise hold them indefinitely until
  # a bootstrap / page-refresh. Callers pass these in from the controller
  # after `@item.destroy`. Cancelled items are NOT included here; they
  # come through delta with `status: "cancelled"` and the store prunes
  # them in `upsertItem`.
  def self.broadcast_changes!(agendas, destroyed_item_ids: [])
    agendas = Array(agendas).compact.uniq
    return if agendas.empty?

    destroyed_ids = Array(destroyed_item_ids).map(&:to_s).compact_blank
    agenda_ids = agendas.map(&:id)

    # Per-agenda access_users would fire (count_shares + 1) queries per
    # agenda — a multi-agenda change (item move) compounds the cost. Build
    # the agenda_id → user_ids map in two batched queries instead: one
    # for owners (already in-memory on the records) and one for every
    # share row across all touched agendas.
    user_ids_by_agenda = Hash.new { |h, k| h[k] = [] }
    agendas.each { |a| user_ids_by_agenda[a.id] << a.user_id }
    AgendaShare.where(agenda_id: agenda_ids).pluck(:agenda_id, :user_id).each do |aid, uid|
      user_ids_by_agenda[aid] << uid
    end

    # Pivot agenda→users to user→accessible-agendas. Compact + dedup at the
    # end so the per-user fan-out matches what each user actually sees.
    per_user_ids = Hash.new { |h, k| h[k] = [] }
    agendas.each do |a|
      user_ids_by_agenda[a.id].uniq.each { |uid| per_user_ids[uid] << a }
    end

    User.where(id: per_user_ids.keys).find_each do |user|
      accessible = per_user_ids[user.id]
      MonitorChannel.broadcast_to(user, {
        id:        :agenda,
        channel:   :agenda,
        timestamp: Time.current.to_i,
        data:      {
          changed:            accessible.map { |a| { agenda_id: a.id, slug: a.parameterized_name } },
          destroyed_item_ids: destroyed_ids,
        },
      })
    end
  end

  private

  # Cheap pruning — jsonb `@>` lets Postgres find the matching rows via a
  # GIN index if one exists, falls back to a sequential scan otherwise.
  # Single-id arrays are rare enough that the scan cost is negligible.
  # Broadcasts the new snapshot per affected user so any other open
  # devices drop the orphan id from their cached filter state instead of
  # carrying it around indefinitely.
  def prune_from_user_preferences!
    needle = [id].to_json
    AgendaPreference.where("hidden_agenda_ids @> ?::jsonb", needle).find_each do |pref|
      pref.hidden_agenda_ids = pref.hidden_agenda_ids - [id]
      pref.save!
      pref.broadcast!
    end
  end

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
