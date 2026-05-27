class CreateGoogleAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table :google_accounts do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.string :email, null: false
      # Tokens live in plain text — same security posture as the existing
      # caches.data JSONB they're being moved from. Move to Rails 7
      # encryption later if/when key management is set up.
      t.text :access_token
      t.text :refresh_token
      t.text :id_token
      t.datetime :tokens_refreshed_at
      t.datetime :reauth_required_at

      t.timestamps
    end

    add_index :google_accounts, [:user_id, :email], unique: true

    add_reference :agendas, :google_account, foreign_key: true, index: true
  end
end
