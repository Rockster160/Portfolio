class NullifyBankTransactionActionEventOnDelete < ActiveRecord::Migration[7.1]
  # ActionEvents get deleted — from the app, from Buddy's delete tool, from its
  # undo. With a plain foreign key that raises the moment the deleted event is
  # one a bank transaction had been linked to. The bank row is the
  # authoritative record and must outlive the annotation, so drop the link
  # rather than the row.
  def up
    remove_foreign_key :bank_transactions, :action_events
    add_foreign_key :bank_transactions, :action_events, on_delete: :nullify
  end

  def down
    remove_foreign_key :bank_transactions, :action_events
    add_foreign_key :bank_transactions, :action_events
  end
end
