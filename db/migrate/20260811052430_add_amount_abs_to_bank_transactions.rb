class AddAmountAbsToBankTransactions < ActiveRecord::Migration[7.1]
  # Searching by amount has to work with `>` and `<`, and a search term backed
  # by a scope never receives the operator — only a real column goes down the
  # numeric-comparison path. So magnitude gets its own column.
  #
  # This WANTED to be `GENERATED ALWAYS AS (abs(amount_cents)/100) STORED`,
  # which cannot drift. Production is PostgreSQL 9.5 and generated columns
  # arrived in 12, so it is a plain column kept correct by a before_save on
  # BankTransaction instead. `null: false` is the guard: anything that writes a
  # row around the model fails loudly here rather than going quietly missing
  # from every `amount` search.
  #
  # In dollars, because that is what gets typed. `amount>100` means $100.
  def up
    add_column :bank_transactions, :amount_abs, :decimal
    execute("UPDATE bank_transactions SET amount_abs = abs(amount_cents)::numeric / 100")
    change_column_null :bank_transactions, :amount_abs, false

    add_index :bank_transactions, :amount_abs
  end

  def down
    remove_column :bank_transactions, :amount_abs
  end
end
