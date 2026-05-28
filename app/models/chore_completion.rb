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
  belongs_to :chore
  belongs_to :user

  # History search via the app-wide `.query(q)` scope.
  #   notes:test            → notes ILIKE %test%
  #   time>2026-05-01       → completed_at > date
  #   name:Cat              → joined chore.name ILIKE %Cat%
  #   bare keyword          → matches across notes + chore name
  search_terms :id, :note, :paid_pebbles,
    notes: :note,
    time: :completed_at,
    name: "chores.name"

  scope :for_day, ->(day) { where(day_key: day) }
  scope :paid, -> { where(payout_skipped: false) }
end
