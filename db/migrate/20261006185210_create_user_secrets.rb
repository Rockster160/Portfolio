class CreateUserSecrets < ActiveRecord::Migration[7.1]
  def change
    create_table(:user_secrets) { |t|
      t.references :user, null: false, foreign_key: true
      t.text :name, null: false
      t.text :value, null: false

      t.timestamps
    }

    add_index :user_secrets, "user_id, LOWER(name)", unique: true
  end
end
