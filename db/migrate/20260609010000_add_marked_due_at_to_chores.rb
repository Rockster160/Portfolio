class AddMarkedDueAtToChores < ActiveRecord::Migration[7.1]
  # Timestamp the user stamps when they verbally / via UI say "this chore
  # needs to get done." While set, the chore appears in Today (if marked
  # this chore-day) or Scheduled/overdue (if marked earlier), regardless
  # of its normal schedule. Any ChoreCompletion clears the stamp.
  def change
    add_column :chores, :marked_due_at, :datetime
  end
end
