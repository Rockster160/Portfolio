class CreateBankTransactions < ActiveRecord::Migration[7.1]
  def change
    create_table(:bank_transactions) { |t|
      t.string :simplefin_id, null: false
      t.references :bank_account, null: false, foreign_key: true
      t.datetime :posted_at, null: false
      # When the purchase actually happened, which can be days before it
      # posts. Optional in the protocol.
      t.datetime :transacted_at
      t.bigint :amount_cents, null: false
      t.text :description
      t.string :payee
      t.text :memo
      t.string :mcc
      t.boolean :pending, null: false, default: false

      t.timestamps
    }

    add_index :bank_transactions, :simplefin_id, unique: true
    add_index :bank_transactions, [:bank_account_id, :posted_at]
  end
end
