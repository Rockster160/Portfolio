class CreateShortLinks < ActiveRecord::Migration[7.1]
  def change
    create_table(:short_links) { |t|
      t.references :user, null: false, foreign_key: true
      t.text :key, null: false
      t.text :url, null: false
      t.integer :visits, null: false, default: 0

      t.timestamps
    }

    add_index :short_links, :key, unique: true
  end
end
