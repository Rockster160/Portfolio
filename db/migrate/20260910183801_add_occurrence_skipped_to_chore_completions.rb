class AddOccurrenceSkippedToChoreCompletions < ActiveRecord::Migration[7.1]
  def change
    add_column :chore_completions, :occurrence_skipped, :boolean, default: false, null: false
  end
end
