# == Schema Information
#
# Table name: game_score_entries
#
#  id           :bigint           not null, primary key
#  client_uuid  :uuid             not null
#  delta        :integer          not null
#  entered_at   :datetime         not null
#  player_name  :text             not null
#  voided_at    :datetime
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  game_play_id :bigint           not null
#
class GameScoreEntry < ApplicationRecord
  belongs_to :game_play

  validates :player_name, :delta, :entered_at, :client_uuid, presence: true
  validates :client_uuid, uniqueness: true

  scope :live, -> { where(voided_at: nil) }
  scope :ordered, -> { order(:entered_at) }

  def void!
    update!(voided_at: Time.current) unless voided_at
  end
end
