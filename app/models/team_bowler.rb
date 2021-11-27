# == Schema Information
#
# Table name: team_bowlers
#
#  id              :integer          not null, primary key
#  total_games     :integer
#  total_pins    :integer
#  bowler_id       :integer
#  bowling_team_id :integer
#

class TeamBowler < ApplicationRecord
end
