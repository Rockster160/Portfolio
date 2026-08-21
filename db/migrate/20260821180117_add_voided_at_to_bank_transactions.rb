class AddVoidedAtToBankTransactions < ActiveRecord::Migration[7.1]
  # A charge that was authorized and then cancelled never posts, so nothing
  # ever arrives to net it off the way a refund would — it sits in every total
  # forever. Stamped rather than boolean so the listing can say when it was
  # marked, and partial because the overwhelming majority of rows are NULL.
  def change
    add_column(:bank_transactions, :voided_at, :datetime)
    add_index(:bank_transactions, :voided_at, where: "voided_at IS NOT NULL")
  end
end
