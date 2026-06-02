class FinalizeChoreHouseholds < ActiveRecord::Migration[7.1]
  def change
    change_column_null :chores, :chore_household_id, false
    change_column_null :chore_streak_bonuses, :chore_household_id, false

    remove_index :chores, :sharing_mode, if_exists: true
    remove_index :chores, :created_by_user_id, if_exists: true

    remove_reference :chore_streak_bonuses, :user, foreign_key: true, index: true

    drop_table :chore_user_orders do |t|
      t.bigint :user_id, null: false
      t.bigint :chore_id, null: false
      t.integer :sort_order, null: false
      t.timestamps
    end

    drop_table :chore_shares do |t|
      t.bigint :user_id, null: false
      t.bigint :shared_with_user_id, null: false
      t.timestamps
    end
  end
end
