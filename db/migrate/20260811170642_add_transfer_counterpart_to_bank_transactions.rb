class AddTransferCounterpartToBankTransactions < ActiveRecord::Migration[7.1]
  # Money moved between two accounts that are both mine shows up twice — once
  # leaving, once arriving. Counted naively that is a phantom spend AND a
  # phantom deposit of the same size: a card payoff reads as if the money was
  # spent twice, having already been spent on the card itself.
  #
  # Each side points at the other, so a pair is discoverable from either row
  # and the relationship is symmetric. Partial-unique because a row can belong
  # to exactly one pair — without it, three same-amount movements in a week
  # could chain and silently mis-pair.
  def change
    add_column :bank_transactions, :transfer_counterpart_id, :bigint
    add_foreign_key :bank_transactions, :bank_transactions,
      column: :transfer_counterpart_id, on_delete: :nullify

    add_index :bank_transactions, :transfer_counterpart_id,
      unique: true,
      where:  "transfer_counterpart_id IS NOT NULL",
      name:   :index_bank_transactions_on_claimed_transfer
  end
end
