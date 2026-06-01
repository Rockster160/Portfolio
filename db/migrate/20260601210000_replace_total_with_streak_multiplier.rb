class ReplaceTotalWithStreakMultiplier < ActiveRecord::Migration[7.1]
  def up
    add_column :chore_completions, :streak_multiplier, :float, null: false, default: 1.0

    # Backfill: for each row, derive the streak (user-side) multiplier
    # from whichever signal is still trustworthy. Order of preference:
    #   1. metadata.user_multiplier — exact value captured by
    #      ChoreCompleter at write time
    #   2. total_multiplier / hot_multiplier — the legacy column stored
    #      the cumulative (hot × user) product; dividing recovers user
    #   3. 1.0 fallback for rows with neither signal
    execute(<<~SQL)
      UPDATE chore_completions
      SET streak_multiplier = COALESCE(
        NULLIF((metadata #>> '{user_multiplier}')::float, 0),
        CASE WHEN hot_multiplier > 0
             THEN ROUND((total_multiplier / hot_multiplier)::numeric, 3)::float
             ELSE 1.0
        END
      )
    SQL

    remove_column :chore_completions, :total_multiplier
  end

  def down
    add_column :chore_completions, :total_multiplier, :float, null: false, default: 1.0
    execute(<<~SQL)
      UPDATE chore_completions
      SET total_multiplier = ROUND((hot_multiplier * streak_multiplier)::numeric, 3)::float
    SQL
    remove_column :chore_completions, :streak_multiplier
  end
end
