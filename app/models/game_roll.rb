# == Schema Information
#
# Table name: game_rolls
#
#  id           :bigint           not null, primary key
#  client_uuid  :uuid             not null
#  dice         :text             not null
#  faces        :jsonb
#  player_index :integer          not null
#  player_name  :text             not null
#  rolled_at    :datetime         not null
#  source       :integer          default("button"), not null
#  value        :integer          not null
#  voided_at    :datetime
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  game_play_id :bigint           not null
#
class GameRoll < ApplicationRecord
  SOURCES = { button: 0, custom: 1, virtual: 2 }.freeze
  enum :source, SOURCES

  belongs_to :game_play

  validates :player_name, :value, :dice, :rolled_at, :client_uuid, presence: true
  validates :client_uuid, uniqueness: true

  scope :live, -> { where(voided_at: nil) }
  scope :ordered, -> { order(:rolled_at) }

  def void!
    update!(voided_at: Time.current) unless voided_at
  end
end
