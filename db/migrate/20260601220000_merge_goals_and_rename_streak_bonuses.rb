class MergeGoalsAndRenameStreakBonuses < ActiveRecord::Migration[7.1]
  def change
    # Achievements collapse into the unified ChoreGoal model — same
    # progress-bar shape, same "permanently completed on reach" flow.
    # No production data to migrate.
    drop_table :user_chore_achievements
    drop_table :chore_achievements

    # ChoreGoal becomes the unified goal/achievement record.
    change_table :chore_goals do |t|
      t.integer :kind,             null: false, default: 0
      t.integer :scope_mode,       null: false, default: 0
      t.integer :tracking_mode,    null: false, default: 0
      t.integer :target_value,     null: false, default: 0
      t.integer :baseline_value,   null: false, default: 0
      t.integer :awarded_pebbles,  null: false, default: 0
      t.text    :description
      t.jsonb   :config,           null: false, default: {}
    end
    remove_column :chore_goals, :cost_pebbles, :integer, default: 0, null: false

    # ChoreMultiplier → ChoreStreakBonus. Pebble-threshold kinds aren't
    # really per-chore (they fire on any completion when the cumulative
    # crosses the threshold) — chore_id becomes nullable; the model
    # validates presence only for the chore-specific kind.
    rename_table :chore_multipliers, :chore_streak_bonuses
    change_column_null :chore_streak_bonuses, :chore_id, true
  end
end
