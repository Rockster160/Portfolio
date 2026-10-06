class CreateGameScoreEntries < ActiveRecord::Migration[7.1]
  def change
    create_table :game_score_entries do |t|
      t.references :game_play, null: false, foreign_key: true
      t.text :player_name, null: false
      t.integer :delta, null: false
      t.datetime :entered_at, null: false
      t.uuid :client_uuid, null: false
      t.datetime :voided_at

      t.timestamps
    end

    add_index :game_score_entries, :client_uuid, unique: true
    add_index :game_score_entries, [:game_play_id, :entered_at]
  end
end
