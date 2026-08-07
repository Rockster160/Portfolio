class AddPriorityToChores < ActiveRecord::Migration[7.1]
  def change
    # Integer-backed so the stored value sorts directly: higher number =
    # more urgent. `ORDER BY priority DESC` is the Today/Scheduled sort
    # key, and a new level slots in without renumbering the rest.
    add_column :chores, :priority, :integer, default: 2, null: false
  end
end
