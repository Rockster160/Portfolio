class AddCompletedToBowlingGame < ActiveRecord::Migration[7.1]
  def change
    add_column :bowling_games, :completed, :boolean, default: false
    BowlingGame.update_all(completed: true)
  end
end
