class AddSpecificFieldsForLeagueHdcpCalc < ActiveRecord::Migration[5.0]
  def change
    add_column :bowling_leagues, :hdcp_base, :integer, default: 210
    add_column :bowling_leagues, :hdcp_factor, :float, default: 0.95
    remove_column :bowling_leagues, :handicap_calculation, :string, default: "(210 - AVG) * 0.95"
  end
end
