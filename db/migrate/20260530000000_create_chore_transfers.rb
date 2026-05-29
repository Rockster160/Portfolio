class CreateChoreTransfers < ActiveRecord::Migration[7.1]
  def change
    create_table :chore_transfers do |t|
      t.references :from_user, null: false, foreign_key: { to_table: :users }
      t.references :to_user,   null: false, foreign_key: { to_table: :users }
      t.integer :amount_pebbles, null: false
      t.text :note
      t.timestamps
    end
    add_check_constraint :chore_transfers,
      "from_user_id <> to_user_id", name: "chore_transfers_distinct_endpoints"
    add_check_constraint :chore_transfers,
      "amount_pebbles > 0", name: "chore_transfers_positive_amount"
  end
end
