class CreateBowlingGame < ActiveRecord::Migration[5.0]
  def change
    create_table :bowling_games do |t|
      t.text :game_data

      t.timestamps
    end
  end
end
