class CreateDeviceLoginTokens < ActiveRecord::Migration[7.1]
  def change
    create_table(:device_login_tokens) { |t|
      t.references :user, null: false, foreign_key: true
      # Bearer credential embedded in the QR link.
      t.string :token, null: false
      # Typed into the password field on another device.
      t.string :code, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      # Wrong-code guesses against this token. Caps brute force on the
      # short numeric code within its lifetime.
      t.integer :attempts, null: false, default: 0

      t.timestamps
    }

    add_index :device_login_tokens, :token, unique: true
  end
end
