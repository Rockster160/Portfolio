class AddFriendlyNameToBankAccounts < ActiveRecord::Migration[7.1]
  def change
    change_table(:bank_accounts, bulk: true) { |t|
      # `name` stays as the institution reports it ("PREMIER PLUS CKG (2363)")
      # so a rename upstream is visible. This is what gets rendered.
      t.string :friendly_name

      # Parsed out of the reported name. The existing Transaction ActionEvents
      # identify their account only by trailing digits — "(...8257)" — across
      # at least five different name spellings, so this is the join key
      # between the two histories.
      t.string :last4
    }

    add_index :bank_accounts, :last4
  end
end
