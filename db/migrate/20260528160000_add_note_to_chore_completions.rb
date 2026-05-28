class AddNoteToChoreCompletions < ActiveRecord::Migration[7.1]
  def change
    add_column :chore_completions, :note, :text
  end
end
