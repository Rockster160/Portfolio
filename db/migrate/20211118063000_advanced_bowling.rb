class AdvancedBowling < ActiveRecord::Migration[5.0]
  def change
    drop_table :bowling_games, if_exists: true
    create_table :bowling_leagues do |t|
      t.belongs_to :user

      t.text :name
      t.text :team_name
      t.text :handicap_calculation, default: 0
      # (210 - AVG) * 0.95
      t.integer :games_per_series, default: 3

      t.timestamps
    end

    create_table :bowlers do |t|
      t.belongs_to :league
      t.integer :position

      t.text :name
      t.integer :total_pins
      t.integer :total_games
      t.integer :total_points

      t.timestamps
    end

    create_table :bowling_sets do |t|
      t.belongs_to :league
      t.text :winner
      # has_many games

      t.timestamps
    end

    create_table :bowling_games do |t|
      t.belongs_to :bowler
      t.belongs_to :set

      t.integer :position
      t.integer :game_num

      t.integer :score
      t.integer :handicap
      t.text :frames
      t.boolean :card_point, default: false
      t.boolean :game_point, default: false

      t.timestamps
    end
  end
end
