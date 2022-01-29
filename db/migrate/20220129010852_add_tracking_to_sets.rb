class AddTrackingToSets < ActiveRecord::Migration[5.0]
  def change
    create_table :bowler_sets do |t|
      t.belongs_to :bowler
      t.belongs_to :set
      t.integer :handicap
      t.integer :absent_score
      t.integer :starting_avg
      t.integer :ending_avg
      t.integer :this_avg

      t.timestamps
    end

    reversible do |migration|
      migration.up do
        BowlingSet.find_each do |set|
          set.bowlers.each do |bowler|
            set.bowler_sets.find_or_create_by(bowler: bowler).recalc
          end
        end
      end
    end
  end
end
