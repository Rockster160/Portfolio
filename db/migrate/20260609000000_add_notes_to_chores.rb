class AddNotesToChores < ActiveRecord::Migration[7.1]
  # Free-form notes the user dumps into the chore edit modal — separate
  # from the existing `notes_template` (which scaffolds the
  # completion-time prompt). No special behavior; just stored text the
  # user can read when reopening the edit form.
  def change
    add_column :chores, :notes, :text
  end
end
