class RemoveIconFromBackgroundProcesses < ActiveRecord::Migration[7.1]
  # The chip is one line now. An emoji on the front of it cost a character of a
  # twenty-character name and said what the colour already says - amber is
  # waiting on you, red is dead - so it went, and the column with it.
  #
  # A second migration rather than an edit to the first: `background_processes`
  # shipped, so 20260916162438 has already run in production and the filename
  # IS the key in `schema_migrations`. Editing it would leave prod carrying a
  # column nothing else knows about.
  def change
    remove_column :background_processes, :icon, :string
  end
end
