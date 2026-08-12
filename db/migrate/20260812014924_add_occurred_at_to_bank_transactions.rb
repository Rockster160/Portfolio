class AddOccurredAtToBankTransactions < ActiveRecord::Migration[7.1]
  # The date the table shows is `transacted_at || posted_at` — when the purchase
  # happened, not when it cleared. Those are a different DAY on 83% of rows and
  # up to four days apart, so searching by `posted_at` means searching a date
  # the page never displayed.
  #
  # It has to be a real column rather than a method or a scope: a search term
  # backed by a scope never receives the operator, and only a column goes down
  # the date-comparison path that `>=` and `<` need. Same reasoning, and the
  # same PostgreSQL 9.5 constraint, as amount_abs — this wanted to be
  # `GENERATED ALWAYS AS (coalesce(transacted_at, posted_at)) STORED` and is a
  # before_save instead.
  #
  # `null: false` because posted_at already is: a row that cannot answer "when"
  # should fail here rather than vanish from every date search.
  def up
    add_column :bank_transactions, :occurred_at, :datetime
    execute("UPDATE bank_transactions SET occurred_at = COALESCE(transacted_at, posted_at)")
    change_column_null :bank_transactions, :occurred_at, false

    add_index :bank_transactions, :occurred_at
  end

  def down
    remove_column :bank_transactions, :occurred_at
  end
end
