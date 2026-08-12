# == Schema Information
#
# Table name: chore_completions
#
#  id                        :bigint           not null, primary key
#  achievement_bonus_pebbles :integer          default(0), not null
#  anonymous                 :boolean          default(FALSE), not null
#  base_pebbles              :integer          default(0), not null
#  completed_at              :datetime         not null
#  day_key                   :date             not null
#  hot_multiplier            :float            default(1.0), not null
#  metadata                  :jsonb            not null
#  note                      :text
#  paid_pebbles              :integer          default(0), not null
#  payout_skipped            :boolean          default(FALSE), not null
#  skipped_reason            :text
#  streak_multiplier         :float            default(1.0), not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  chore_id                  :bigint           not null
#  client_mutation_id        :string
#  parent_chore_id           :bigint
#  user_id                   :bigint           not null
#
class ChoreCompletion < ApplicationRecord
  include Jilable

  belongs_to :chore
  belongs_to :user
  # `chore_id` is the ACTUAL chore that was tapped. When the tapped chore
  # is a sub-chore, `parent_chore_id` denormalizes `chore.parent_chore_id`
  # so parent-level aggregations (the parent card's "done today across all
  # sub-chores", threshold windows shared across siblings) are a single
  # `WHERE parent_chore_id = X` away instead of a JOIN.
  belongs_to :parent_chore, class_name: "Chore", optional: true

  before_validation :sync_parent_chore_id

  # Fan out lifecycle as Jil triggers so users can wire automations
  # against chore completion + undo (e.g. log an ActionEvent, post to
  # SMS, etc.). Pattern mirrors AgendaItem / Task / ActionEvent.
  after_create_commit  :fire_jil_create_trigger
  after_update_commit  :fire_jil_update_trigger
  after_destroy_commit :fire_jil_destroy_trigger
  # Note: marked_due_at is NOT cleared here on completion. Same-day
  # mutations would shift the chore's slot in the Today tab, violating
  # the "locked at 4am" contract. ChoreDailyResetWorker clears it at
  # the next chore-day rollover for any chore with a completion that
  # postdates the mark.

  # History search via the app-wide `.query(q)` scope.
  #   notes:test            → notes ILIKE %test%
  #   time>2026-05-01       → completed_at > date
  #   name:Cat              → joined chore.name ILIKE %Cat%
  #   amount>1              → paid_pebbles > 1 (=, !=, <, >, <=, >=)
  #   bare keyword          → matches across notes + chore name
  # `name:` reaches through to the chore, so every search term has to be
  # resolvable with `chores` in scope. Without this the `name:` branch built SQL
  # saying `chores.name ILIKE ...` against a bare `chore_completions` — and
  # `raw_sql` RUNS the fragment to validate it, so it raised UndefinedTable
  # every time. ChoresController#safe_query rescues and returns the unfiltered
  # scope, which is why history search by name quietly returned everything
  # instead of erroring. Left-outer to match LogTracker: `stripped_sql` knows
  # how to strip a LEFT OUTER JOIN off the front of a fragment and does not
  # know how to strip an INNER one.
  def self.search_scope
    left_outer_joins(:chore).references(:chore)
  end

  search_terms :id, :note, :paid_pebbles,
    notes:  :note,
    amount: :paid_pebbles,
    time:   :completed_at,
    is:     :is_search,
    name:   "chores.name"

  scope :for_day, ->(day) { where(day_key: day) }

  # `is:today` — a RELATIVE window, which is the only kind a stored condition
  # can use. `time>2026-08-12` is fine typed into a search box and useless
  # written into a reminder that fires every night, since the date it was
  # authored on is not the date it runs on.
  #
  # Days here are CHORE days, not calendar days: the boundary is the household's
  # reset (see ChoreDay), so a chore ticked off at 1am still counts for the
  # evening it belonged to. `day_key` is stamped at completion from exactly that
  # notion, so this is a plain indexed column compare rather than a clock
  # calculation done twice and hoped to agree.
  #
  # Mirrors AgendaItem#is_search, including returning `none` for a word it
  # doesn't know — a filter that silently matched everything would read as
  # "condition satisfied" and fire the thing it was meant to hold back.
  scope :is_search, ->(val) {
    today = ::ChoreDay.current
    case val.to_s.downcase
    when "today"                then for_day(today)
    when "yesterday"            then for_day(today - 1)
    when "week"                 then where(day_key: (today - 6)..today)
    when "credited"             then credited
    when "anonymous"            then where(anonymous: true)
    when "paid"                 then paid
    when "skipped"              then where(payout_skipped: true)
    else none
    end
  }
  scope :paid, -> { where(payout_skipped: false) }
  # "Credited" = counts as someone's done-by-me action. Anonymous
  # completions still satisfy the schedule + cooldown (the work got
  # done) but are NOT attributed to any household member, so they're
  # excluded from done_count_today, actor display, and streak math.
  scope :credited, -> { where(anonymous: false) }

  # Snapshot of the fields a Jil task is most likely to want to read
  # off `chore_completion.*` — the chore name + paid amount + day key
  # + skipped reason. Keeps the trigger payload self-contained so
  # listeners don't have to round-trip to the DB for common fields.
  #
  # `changes` (optional) is a saved_changes-style hash of
  # `{ field => [old, new] }`. Surfaced on :edited so listeners can
  # tell what actually changed (and skip work when their interest
  # didn't move) without re-querying the DB.
  def jil_attrs(action:, changes: nil)
    base = {
      id:                    id,
      action:                action,
      chore_id:              chore_id,
      chore_name:            chore&.name,
      parent_chore_id:       parent_chore_id,
      parent_chore_name:     parent_chore&.name,
      paid_pebbles:          paid_pebbles,
      payout_skipped:        payout_skipped,
      skipped_reason:        skipped_reason,
      day_key:               day_key&.iso8601,
      completed_at:          completed_at&.iso8601(3),
      completed_by_user_id:  user_id,
      completed_by_username: user&.username,
      metadata:              metadata || {},
    }
    base[:changes] = changes if changes.present?
    base
  end

  private

  # Denormalized so sibling / parent-aggregate queries don't need a JOIN.
  # Refreshed on every save — a completion moved to a different chore
  # (History-page reassignment) picks up the new chore's parent.
  def sync_parent_chore_id
    self.parent_chore_id = chore&.parent_chore_id
  end

  def fire_jil_create_trigger
    return if anonymous

    fan_out_trigger(jil_attrs(action: :completed))
  end

  def fire_jil_update_trigger
    # No-op when nothing actually changed (Rails can fire after_update_commit
    # on touch-only saves). The trigger payload exposes saved_changes so
    # listeners can compare old vs new and short-circuit idempotently.
    return if saved_changes.blank?
    return if anonymous

    fan_out_trigger(jil_attrs(action: :edited, changes: saved_changes))
  end

  def fire_jil_destroy_trigger
    return if anonymous

    fan_out_trigger(jil_attrs(action: :uncompleted))
  end

  # Household-shared chores fire the trigger against every household
  # member so listener tasks owned by any member fire — otherwise a
  # completion by one member silently no-ops another member's
  # automations (e.g. "remove list item on completion"). Personal
  # chores stay scoped to the completing user.
  def fan_out_trigger(attrs)
    payload = with_jil_attrs(attrs)
    trigger_target_users.each do |target|
      ::Jil.trigger(target, :chore_completion, payload)
    end
  end

  def trigger_target_users
    return [user] unless chore.share_household?

    User.where(chore_household_id: chore.chore_household_id).to_a
  end

end
