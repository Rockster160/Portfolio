class CreateGameTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :game_templates do |t|
      t.references :user, null: false, foreign_key: true
      t.text :name, null: false
      t.text :dice
      t.integer :scoring, null: false, default: 0
      t.integer :win, null: false, default: 0
      t.boolean :auto_advance, null: false, default: true
      t.jsonb :score_presets, null: false, default: []
      t.jsonb :aliases, null: false, default: []

      t.timestamps
    end

    add_index :game_templates, [:user_id, :name], unique: true
  end
end
