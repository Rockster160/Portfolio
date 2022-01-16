class BowlingUpdates < ActiveRecord::Migration[5.0]
  def change
    add_column :bowlers, :high_game, :integer
    add_column :bowlers, :high_series, :integer
    add_column :bowlers, :total_pins_offset, :integer
    add_column :bowlers, :total_games_offset, :integer
    add_column :bowling_games, :absent, :boolean
    add_column :bowling_games, :frame_details, :jsonb
    add_column :bowling_leagues, :absent_calculation, :text, default: "AVG - 10"
    change_column_default :bowling_leagues, :handicap_calculation, from: 0, to: "(210 - AVG) * 0.95"
  end
end
