# == Schema Information
#
# Table name: chore_completions
#
#  id                        :bigint           not null, primary key
#  achievement_bonus_pebbles :integer          default(0), not null
#  base_pebbles              :integer          default(0), not null
#  completed_at              :datetime         not null
#  day_key                   :date             not null
#  hot_multiplier            :float            default(1.0), not null
#  metadata                  :jsonb            not null
#  note                      :text
#  paid_pebbles              :integer          default(0), not null
#  payout_skipped            :boolean          default(FALSE), not null
#  skipped_reason            :text
#  total_multiplier          :float            default(1.0), not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  chore_id                  :bigint           not null
#  user_id                   :bigint           not null
#
class ChoreCompletion < ApplicationRecord
  include Jilable

  belongs_to :chore
  belongs_to :user
  has_many :user_chore_achievements, dependent: :destroy

  # Fan out lifecycle as Jil triggers so users can wire automations
  # against chore completion + undo (e.g. log an ActionEvent, post to
  # SMS, etc.). Pattern mirrors AgendaItem / Task / ActionEvent.
  after_create_commit  :fire_jil_create_trigger
  after_update_commit  :fire_jil_update_trigger
  after_destroy_commit :fire_jil_destroy_trigger

  # History search via the app-wide `.query(q)` scope.
  #   notes:test            → notes ILIKE %test%
  #   time>2026-05-01       → completed_at > date
  #   name:Cat              → joined chore.name ILIKE %Cat%
  #   amount>1              → paid_pebbles > 1 (=, !=, <, >, <=, >=)
  #   bare keyword          → matches across notes + chore name
  search_terms :id, :note, :paid_pebbles,
    notes:  :note,
    amount: :paid_pebbles,
    time:   :completed_at,
    name:   "chores.name"

  scope :for_day, ->(day) { where(day_key: day) }
  scope :paid, -> { where(payout_skipped: false) }

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
      id:             id,
      action:         action,
      chore_id:       chore_id,
      chore_name:     chore&.name,
      paid_pebbles:   paid_pebbles,
      payout_skipped: payout_skipped,
      skipped_reason: skipped_reason,
      day_key:        day_key&.iso8601,
      completed_at:   completed_at&.iso8601(3),
      metadata:       metadata || {},
    }
    base[:changes] = changes if changes.present?
    base
  end

  private

  def fire_jil_create_trigger
    ::Jil.trigger(user, :chore_completion, with_jil_attrs(jil_attrs(action: :completed)))
  end

  def fire_jil_update_trigger
    # No-op when nothing actually changed (Rails can fire after_update_commit
    # on touch-only saves). The trigger payload exposes saved_changes so
    # listeners can compare old vs new and short-circuit idempotently.
    return if saved_changes.blank?

    ::Jil.trigger(user, :chore_completion, with_jil_attrs(jil_attrs(action: :edited, changes: saved_changes)))
  end

  def fire_jil_destroy_trigger
    ::Jil.trigger(user, :chore_completion, with_jil_attrs(jil_attrs(action: :uncompleted)))
  end
end
