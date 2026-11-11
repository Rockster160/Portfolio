# == Schema Information
#
# Table name: game_templates
#
#  id            :bigint           not null, primary key
#  aliases       :jsonb            not null
#  auto_advance  :boolean          default(TRUE), not null
#  dice          :text
#  first_player  :integer          default("keep"), not null
#  name          :text             not null
#  phases        :jsonb            not null
#  score_presets :jsonb            not null
#  scoring       :integer          default("individual"), not null
#  setup_notes   :text
#  win           :integer          default("high"), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :bigint           not null
#
class GameTemplate < ApplicationRecord
  SCORINGS = { individual: 0, teams: 1, table: 2 }.freeze
  WINS = { high: 0, low: 1, none: 2 }.freeze
  FIRST_PLAYERS = { keep: 0, rotate: 1, lowest_score: 2, highest_score: 3 }.freeze
  # "Swarm (each player x2)" - every player takes a turn through the steps,
  # twice around the table, before the next phase.
  EACH_PLAYER = /\((?:each|every)\s+player(?:\s*[x×]\s*(\d+))?\)/i
  COLOR = /#(\h{3,8})\b/
  MAX_SCORE_PRESETS = 6
  # "3 Assimilate" or "Assimilate 3" - an amount, and the name on its button.
  PRESET_AMOUNT_FIRST = /\A\+?(\d+)\s*(.*)\z/
  PRESET_AMOUNT_LAST = /\A(.*?)\s*\+?(\d+)\z/

  enum :scoring, SCORINGS, scopes: false
  enum :win, WINS, scopes: false
  enum :first_player, FIRST_PLAYERS, prefix: true, scopes: false

  belongs_to :user
  has_many :game_plays, dependent: :nullify
  # Photos for the setup notes, linked from the markdown by their blob path.
  has_many_attached :setup_images

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

  # One phase per line, the same shape as a Timers dial:
  #   Emerge #E8A83E: Nodes Pulse, Springs Yield
  #   Swarm #D4644E (each player x2): 2, 1, 0
  # A color on a step is dropped - steps take their phase's color.
  def self.parse_phases(text)
    text.to_s.lines.map(&:strip).compact_blank.filter_map { |line|
      head, tail = line.split(":", 2)
      laps = [::Regexp.last_match(1).to_i, 1].max if head.match(EACH_PLAYER)
      head = head.sub(EACH_PLAYER, " ")
      color = "##{::Regexp.last_match(1).downcase}" if head.match(COLOR)
      head = head.sub(COLOR, " ")
      name = head.squish
      next if name.blank?

      steps = tail.to_s.split(",").map { |step| step.gsub(COLOR, " ").squish }.compact_blank
      { name: name, color: color, laps: laps, steps: steps }.compact
    }
  end

  def setup?
    setup_notes.present?
  end

  def setup_html
    Markdown.new(setup_notes.to_s, user: user).to_html if setup?
  end

  # "3 Assimilate, 5 Bloom, 1" - the + Score sheet's buttons, each an amount
  # with an optional name. Older games stored bare numbers; both read back.
  def self.parse_score_presets(text)
    text.to_s.split(/[,\n]/).filter_map { |part|
      part = part.squish
      amount, label = (
        if (match = part.match(PRESET_AMOUNT_FIRST))
          [match[1], match[2]]
        elsif (match = part.match(PRESET_AMOUNT_LAST))
          [match[2], match[1]]
        end
      )
      next unless amount.to_i.positive?

      { amount: amount.to_i, label: label.presence }.compact
    }.uniq.first(MAX_SCORE_PRESETS)
  end

  def score_presets_text
    Array(score_presets).map { |preset|
      preset.is_a?(Hash) ? [preset["amount"], preset["label"]].compact.join(" ") : preset.to_s
    }.join(", ")
  end

  def phases_text
    Array(phases).map { |phase|
      laps = phase["laps"].to_i
      each_player = "(each player#{" x#{laps}" if laps > 1})" if laps.positive?
      head = [phase["name"], phase["color"], each_player].compact.join(" ")
      steps = Array(phase["steps"])
      steps.any? ? "#{head}: #{steps.join(", ")}" : head
    }.join("\n")
  end

  private

  def keep_old_name_as_alias
    old = name_in_database.to_s.strip
    return if old.blank? || old.casecmp?(name.to_s.strip)

    self.aliases = (Array(aliases) + [old]).uniq { |a| a.to_s.downcase }
  end
end
