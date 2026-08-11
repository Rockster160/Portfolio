class AddAmountAbsToBankTransactions < ActiveRecord::Migration[7.1]
  # Searching by amount has to work with `>` and `<`, and a search term backed
  # by a scope never receives the operator — only a real column goes down the
  # numeric-comparison path. So magnitude gets its own column.
  #
  # Generated and stored rather than maintained in the sync: it cannot drift,
  # and it stays correct for rows written by anything else later.
  #
  # In dollars, because that is what gets typed. `amount>100` means $100.
  def change
    add_column :bank_transactions, :amount_abs, :decimal,
      as: "(abs(amount_cents))::numeric / 100", stored: true

    add_index :bank_transactions, :amount_abs
  end
end
