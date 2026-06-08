class AddPartialIndexForActiveChores < ActiveRecord::Migration[7.1]
  # `User#accessible_chores` runs
  #   Chore.where(chore_household_id: X).active.order(sort_order)
  # on every chores page load. The existing
  # `[chore_household_id, archived_at]` index includes archived rows,
  # so as one-offs accumulate (auto-archived daily by
  # `ChoreDailyResetWorker#archive_completed_one_offs!`) the index grows
  # alongside the dead data. A partial index gated on
  # `archived_at IS NULL` excludes archived rows entirely AND orders by
  # `sort_order`, so the live query reads a smaller, presorted slice.
  def change
    add_index :chores,
      [:chore_household_id, :sort_order],
      where: "archived_at IS NULL",
      name: :index_chores_active_by_household_sort
  end
end
