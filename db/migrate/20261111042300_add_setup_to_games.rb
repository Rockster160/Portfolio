class AddSetupToGames < ActiveRecord::Migration[7.1]
  def change
    add_column :game_templates, :setup_notes, :text
    add_column :game_plays, :setup_started_at, :datetime
  end
end
