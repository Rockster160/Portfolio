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

  validates :name, presence: true, uniqueness: { scope: :user_id, case_sensitive: false }
  validates :dice, format: { with: /\A\d*d\d+\z/i, message: "should look like 2d6 or d20" }, allow_blank: true

  # Hand-logged Game events are matched to a game by NAME. Renaming it must
  # not orphan the ones filed under the old name, so the old name becomes an
  # alias.
  before_save :keep_old_name_as_alias, if: -> { persisted? && will_save_change_to_name? }

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

  private

  def keep_old_name_as_alias
    old = name_in_database.to_s.strip
    return if old.blank? || old.casecmp?(name.to_s.strip)

    self.aliases = (Array(aliases) + [old]).uniq { |a| a.to_s.downcase }
  end
end
