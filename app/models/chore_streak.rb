# == Schema Information
#
# Table name: chore_streaks
#
#  id                 :bigint           not null, primary key
#  current_streak     :integer          default(0), not null
#  last_completed_day :date
#  longest_streak     :integer          default(0), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  chore_id           :bigint           not null
#  user_id            :bigint           not null
#
class ChoreStreak < ApplicationRecord
  belongs_to :user
  belongs_to :chore

  # Recompute a chore's streak after a completion is removed (an undo). Walks
  # back day-by-day from the last paid completion in the chore family, counting
  # consecutive days. Extracted from ChoreCompletionsController so the app's
  # tap-undo AND Buddy's undo share ONE streak-rebuild path (see
  # ChoreCompletionUndoer). No-op when there's no streak row for the chore.
  def self.rebuild_for!(user, chore)
    credit_id = chore.parent_chore_id || chore.id
    streak = find_by(user_id: user.id, chore_id: credit_id)
    return if streak.blank?

    family_scope = user.chore_completions.where("chore_id = :id OR parent_chore_id = :id", id: credit_id)
    last_paid = family_scope.where(payout_skipped: false, anonymous: false).order(completed_at: :desc).first

    if last_paid.nil?
      streak.destroy
      return
    end

    cursor = last_paid.day_key
    count  = 0
    loop do
      break unless family_scope.exists?(day_key: cursor, payout_skipped: false, anonymous: false)

      count += 1
      cursor -= 1
    end

    streak.update!(
      current_streak:     count,
      last_completed_day: last_paid.day_key,
      longest_streak:     [streak.longest_streak, count].max,
    )
  end
end
