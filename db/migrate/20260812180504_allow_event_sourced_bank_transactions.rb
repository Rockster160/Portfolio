class AllowEventSourcedBankTransactions < ActiveRecord::Migration[7.1]
  # Makes bank_transactions the one table every transaction lives in, whether
  # the bank reported it or a Chase alert did.
  #
  # Three columns were required because every row used to come from SimpleFIN.
  # A row built from an alert has none of them: no SimpleFIN id, no posted date
  # (an alert fires at purchase time and says nothing about clearing), and on
  # 433 of 2,563 events no account either — that alert format never names one.
  # `occurred_at` stays NOT NULL and becomes the timestamp every row is
  # guaranteed to have.
  #
  # `category` moves here from action_events.data. It was read through the
  # linked event, which meant the ~12,000 rows the historical backfill will
  # produce — and every alert-sourced row for a closed card — could never hold
  # one. Existing values are copied down rather than left for a script, so the
  # page is never briefly uncategorized between deploy and backfill.
  def up
    add_column(:bank_transactions, :category, :string)
    add_index(:bank_transactions, :category)

    execute(
      <<~SQL.squish,
        UPDATE bank_transactions
        SET category = action_events.data->>'category'
        FROM action_events
        WHERE action_events.id = bank_transactions.action_event_id
          AND action_events.data->>'category' IS NOT NULL
      SQL
    )

    change_column_null(:bank_transactions, :simplefin_id, true)
    change_column_null(:bank_transactions, :bank_account_id, true)
    change_column_null(:bank_transactions, :posted_at, true)
  end

  # Rows that only ever existed as alerts have no SimpleFIN id and no posted
  # date, so the NOT NULLs cannot go back on while they are here. They are
  # deleted, which is exactly what going back means — the categories they
  # carried are still on their events, where they came from.
  def down
    execute("DELETE FROM bank_transactions WHERE simplefin_id IS NULL")
    execute("UPDATE bank_transactions SET posted_at = occurred_at WHERE posted_at IS NULL")
    execute("DELETE FROM bank_transactions WHERE bank_account_id IS NULL")

    change_column_null(:bank_transactions, :posted_at, false)
    change_column_null(:bank_transactions, :bank_account_id, false)
    change_column_null(:bank_transactions, :simplefin_id, false)

    remove_index(:bank_transactions, :category)
    remove_column(:bank_transactions, :category)
  end
end
