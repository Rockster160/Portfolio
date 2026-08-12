class CreateBankBalanceSnapshots < ActiveRecord::Migration[7.1]
  # `bank_accounts.balance_cents` is overwritten on every sync, so the balance
  # sheet has no past — only a single frame of now. Transactions can be
  # backfilled from the Bridge; balances cannot, so every day that goes by
  # without a row here is a day that can never be recovered.
  #
  # One row per account per LOCAL day, upserted, so the last sync of the day
  # wins and a day is worth what it ended at. Per account rather than one
  # rolled-up figure: any total can be derived from these, and none of them
  # can be taken back out of a total.
  def change
    create_table(:bank_balance_snapshots) { |t|
      t.references :bank_account, null: false, foreign_key: true, index: false
      t.date :captured_on, null: false
      t.bigint :balance_cents, null: false
      t.bigint :available_balance_cents
      # The institution's own as-of stamp, kept so a flat stretch can be read
      # as "the balance held" rather than "the Bridge stopped refreshing".
      t.datetime :balance_date

      t.timestamps
    }

    add_index :bank_balance_snapshots, [:bank_account_id, :captured_on], unique: true
    add_index :bank_balance_snapshots, :captured_on
  end
end
