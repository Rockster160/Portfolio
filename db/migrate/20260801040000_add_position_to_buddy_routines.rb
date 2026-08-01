class AddPositionToBuddyRoutines < ActiveRecord::Migration[7.1]
  # Pins a routine to the Quick grid in the Buddy hero. NULL means unpinned,
  # which is the default and the reason this isn't a boolean: the grid is
  # ordered, and "which slot" and "is it there at all" are the same fact.
  def change
    add_column :buddy_routines, :position, :integer

    # Partial, because the whole point of the column is that most rows are NULL.
    add_index :buddy_routines, [:user_id, :position],
      where: "position IS NOT NULL", name: "index_buddy_routines_pinned"
  end
end
