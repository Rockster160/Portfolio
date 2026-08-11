class AddActionEventToBankTransactions < ActiveRecord::Migration[7.1]
  def change
    # The Chase alert email fires at purchase time and becomes a categorized
    # ActionEvent; SimpleFIN reports the same purchase up to a day later. The
    # bank row is the authoritative record, the ActionEvent holds the category
    # and any hand-written note, and this points one at the other.
    add_reference :bank_transactions, :action_event, foreign_key: true, null: true

    # One bank transaction per ActionEvent. Without this a near-duplicate
    # charge — same merchant, same amount, same day — could claim an
    # ActionEvent already spoken for, silently double-categorizing it.
    add_index :bank_transactions, :action_event_id,
      unique: true,
      where:  "action_event_id IS NOT NULL",
      name:   :index_bank_transactions_on_claimed_action_event
  end
end
