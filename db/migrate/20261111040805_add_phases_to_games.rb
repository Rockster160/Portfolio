class AddPhasesToGames < ActiveRecord::Migration[7.1]
  def change
    change_table :game_templates, bulk: true do |t|
      t.jsonb :phases, null: false, default: []
      t.integer :first_player, null: false, default: 0
    end
    add_column :game_plays, :phase_state, :jsonb, null: false, default: {}
  end
end
