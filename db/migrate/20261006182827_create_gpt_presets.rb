class CreateGPTPresets < ActiveRecord::Migration[7.1]
  def change
    create_table(:gpt_presets) { |t|
      t.references :user, null: false, foreign_key: true
      t.text :name, null: false
      t.text :instructions, null: false

      t.timestamps
    }

    add_index :gpt_presets, "user_id, LOWER(name)", unique: true
  end
end
