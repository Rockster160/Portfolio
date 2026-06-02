class CreateChoreHouseholds < ActiveRecord::Migration[7.1]
  def change
    create_table :chore_households do |t|
      t.references :owner_user, null: false, foreign_key: { to_table: :users }
      t.text :name, null: false, default: ""
      t.timestamps
    end

    create_table :chore_household_memberships do |t|
      t.references :chore_household, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: true
      t.integer :role, null: false, default: 0
      t.timestamps
    end

    add_index :chore_household_memberships, [:chore_household_id, :user_id],
              unique: true, name: :index_chore_household_memberships_pair
    # One household per user — DB-enforced so the denormalized
    # users.chore_household_id cache stays unambiguous.
    add_index :chore_household_memberships, :user_id,
              unique: true, name: :index_chore_household_memberships_unique_user

    add_reference :chores, :chore_household, foreign_key: true, index: false
    add_index :chores, [:chore_household_id, :archived_at],
              name: :index_chores_on_chore_household_id_and_archived_at
    add_index :chores, [:chore_household_id, :sort_order],
              name: :index_chores_on_chore_household_id_and_sort_order

    add_reference :chore_streak_bonuses, :chore_household, foreign_key: true, index: false
    add_index :chore_streak_bonuses, [:chore_household_id, :active],
              name: :index_chore_streak_bonuses_on_chore_household_id_and_active

    add_reference :users, :chore_household, foreign_key: true, index: true
  end
end
