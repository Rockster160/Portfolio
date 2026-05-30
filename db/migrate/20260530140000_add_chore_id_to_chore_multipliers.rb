class AddChoreIdToChoreMultipliers < ActiveRecord::Migration[7.1]
  def change
    # Every multiplier is scoped to exactly one chore — there's no "applies to
    # every chore" mode. Prod table is empty at deploy time, so NOT NULL is
    # safe without a backfill.
    add_reference :chore_multipliers, :chore, foreign_key: true, null: false
  end
end
