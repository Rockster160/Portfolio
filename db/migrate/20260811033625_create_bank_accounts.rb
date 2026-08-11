class CreateBankAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table(:bank_accounts) { |t|
      t.string :simplefin_id, null: false
      t.string :conn_id
      t.string :name, null: false
      t.string :currency, null: false, default: "USD"
      # Set by hand, never inferred: SimpleFIN reports no account type, and
      # guessing it from the name breaks the first time Chase renames one.
      t.integer :kind, null: false, default: 0
      t.bigint :balance_cents
      # Only meaningful on asset accounts. SimpleFIN reports "0.00" here for
      # cards and loans, which is not an available-credit figure.
      t.bigint :available_balance_cents
      # Straight from the payload. This is the staleness signal — an
      # institution that failed to refresh keeps its old balance-date while
      # still returning a 200.
      t.datetime :balance_date
      t.datetime :last_synced_at

      t.timestamps
    }

    add_index :bank_accounts, :simplefin_id, unique: true
  end
end
