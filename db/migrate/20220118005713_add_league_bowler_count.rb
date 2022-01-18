class AddLeagueBowlerCount < ActiveRecord::Migration[5.0]
  def change
    add_column :bowling_leagues, :team_size, :integer, default: 4
  end
end
