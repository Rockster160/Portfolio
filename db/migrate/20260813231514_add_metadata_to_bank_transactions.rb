class AddMetadataToBankTransactions < ActiveRecord::Migration[7.1]
  # Somewhere for what a transaction is ABOUT, as opposed to what the bank says
  # about it. First use is Amazon: the order number and the ASINs it covered, so
  # a charge can be traced back to the thing that was bought.
  #
  # jsonb and namespaced by source (`metadata->'amazon'`) rather than columns,
  # because every source will name different things — an Amazon order id has
  # nothing in common with whatever the next one carries, and a column per
  # source would be mostly-null forever.
  #
  # Defaults to `{}` rather than NULL so nothing has to guard before digging.
  def change
    add_column(:bank_transactions, :metadata, :jsonb, default: {}, null: false)
    # GIN, not btree: these are looked up by what is INSIDE the document —
    # "which charge covered this ASIN" — not by the document as a whole.
    add_index(:bank_transactions, :metadata, using: :gin)
  end
end
