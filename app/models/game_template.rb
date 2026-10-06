# == Schema Information
#
# Table name: game_templates
#
#  id            :bigint           not null, primary key
#  aliases       :jsonb            not null
#  auto_advance  :boolean          default(TRUE), not null
#  dice          :text
#  name          :text             not null
#  score_presets :jsonb            not null
#  scoring       :integer          default("individual"), not null
#  win           :integer          default("high"), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :bigint           not null
#
class GameTemplate < ApplicationRecord
  SCORINGS = { individual: 0, teams: 1, table: 2 }.freeze
  WINS = { high: 0, low: 1, none: 2 }.freeze

  enum :scoring, SCORINGS, scopes: false
  enum :win, WINS, scopes: false

  belongs_to :user
  has_many :game_plays, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: :user_id }

  scope :by_last_played, -> {
    left_joins(:game_plays).group(:id).order(Arel.sql("MAX(game_plays.started_at) DESC NULLS LAST"))
  }

  # Exact match only (case/whitespace normalized) - [[Mycelia / Mycelia Cards]]
  # must never fold together, so this never does fuzzy matching.
  def self.find_by_alias(user, raw_name)
    name = raw_name.to_s.strip
    return nil if name.blank?

    user.game_templates.find_by(name: name) ||
      user.game_templates.detect { |t| Array(t.aliases).any? { |a| a.to_s.strip == name } }
  end
end
