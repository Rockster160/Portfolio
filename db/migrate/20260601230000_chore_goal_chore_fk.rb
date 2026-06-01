class ChoreGoalChoreFk < ActiveRecord::Migration[7.1]
  def change
    # Hot-path: ChoreGoal.refresh_all_for(user) loads outstanding goals
    # and computes progress for each. A goal whose progress depends on
    # one specific chore needs an indexed FK, not a `config->>'chore_id'`
    # extraction. No production data → straight rename, no backfill.
    add_reference :chore_goals, :chore, foreign_key: true, null: true, index: true
  end
end
