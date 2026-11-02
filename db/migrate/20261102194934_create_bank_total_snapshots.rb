class CreateBankTotalSnapshots < ActiveRecord::Migration[7.1]
  # The dashboard figure as each LOCAL day ended, one row per day. Kept apart
  # from `bank_balance_snapshots` because the past of the total can be
  # reconstructed where the past of each account cannot: the cards' history
  # carries their purchases but not the payments that cleared them, so only
  # the sum across accounts walks back to a believable number.
  def change
    create_table(:bank_total_snapshots) { |t|
      t.date :captured_on, null: false
      t.bigint :total_cents, null: false
      # Walked back from a later figure rather than read off a live sync.
      t.boolean :estimated, null: false, default: false

      t.timestamps
    }

    add_index :bank_total_snapshots, :captured_on, unique: true
  end
end
