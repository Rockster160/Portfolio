class AddTagAndDismissedUntilToChores < ActiveRecord::Migration[7.1]
  def change
    change_table(:chores, bulk: true) { |t|
      # Which group a chore belongs to, and so which board shows it. Free text
      # rather than a table: the set is small, it is the household's own
      # vocabulary, and the form offers what already exists, so a table would
      # only add a record to manage before a chore could be filed.
      t.text :tag
      # Waved off THROUGH this chore-day, inclusive. One column for all three
      # lengths - today, the week, the month - because they differ only in the
      # date, and the 4am ChoreDay rollover is what expires it, so nothing has
      # to go round clearing them.
      t.date :dismissed_until
    }

    add_index :chores, [:chore_household_id, :tag]
  end
end
