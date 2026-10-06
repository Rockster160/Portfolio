class CreateGameRolls < ActiveRecord::Migration[7.1]
  def change
    create_table :game_rolls do |t|
      t.references :game_play, null: false, foreign_key: true
      t.text :player_name, null: false
      t.integer :player_index, null: false
      t.integer :value, null: false
      t.text :dice, null: false
      t.jsonb :faces
      t.integer :source, null: false, default: 0
      t.datetime :rolled_at, null: false
      t.uuid :client_uuid, null: false
      t.datetime :voided_at

      t.timestamps
    end

    add_index :game_rolls, :client_uuid, unique: true
    add_index :game_rolls, [:game_play_id, :rolled_at]
  end
end
