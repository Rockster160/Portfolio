class CreatePlaidItem < ActiveRecord::Migration[5.0]
  def change
    create_table :plaid_items do |t|
      t.belongs_to :user
      t.string :bank_name
      t.text :plaid_item_id
      t.text :plaid_item_access_token

      t.timestamps
    end
  end
end
