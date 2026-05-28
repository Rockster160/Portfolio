class CreateChoreUserOrders < ActiveRecord::Migration[7.1]
  def change
    # Per-user ordering of chores. Each user sees the same chores in
    # their own preferred order. Lazy: rows only exist after the user
    # explicitly reorders. Items without a row fall to the end via
    # `NULLS LAST` ordering, sorted by chore id as a tiebreaker.
    create_table :chore_user_orders do |t|
      t.references :user, null: false, foreign_key: true
      t.references :chore, null: false, foreign_key: true
      t.integer :sort_order, null: false
      t.timestamps
    end

    add_index :chore_user_orders, [:user_id, :chore_id], unique: true, name: :index_chore_user_orders_pair
    add_index :chore_user_orders, [:user_id, :sort_order]
  end
end
