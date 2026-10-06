class CreateGamePlays < ActiveRecord::Migration[7.1]
  def change
    create_table :game_plays do |t|
      t.references :user, null: false, foreign_key: true
      t.references :game_template, foreign_key: true
      t.references :action_event, foreign_key: true
      t.text :name, null: false
      t.jsonb :settings, null: false, default: {}
      t.jsonb :players, null: false, default: []
      t.datetime :started_at
      t.datetime :ended_at
      t.integer :duration_minutes
      t.integer :dice_mode, null: false, default: 0
      t.integer :current_player_index, null: false, default: 0
      t.jsonb :final_scores, null: false, default: {}
      t.jsonb :winner_names, null: false, default: []
      t.integer :status, null: false, default: 0
      t.uuid :client_uuid, null: false

      t.timestamps
    end

    add_index :game_plays, :client_uuid, unique: true
    add_index :game_plays, [:user_id, :status]
  end
end
