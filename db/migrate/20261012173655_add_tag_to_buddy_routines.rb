class AddTagToBuddyRoutines < ActiveRecord::Migration[7.1]
  def change
    add_column :buddy_routines, :tag, :string
  end
end
