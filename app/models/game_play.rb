# == Schema Information
#
# Table name: game_plays
#
#  id                   :bigint           not null, primary key
#  client_uuid          :uuid             not null
#  current_player_index :integer          default(0), not null
#  dice_mode            :integer          default("manual"), not null
#  duration_minutes     :integer
#  ended_at             :datetime
#  final_scores         :jsonb            not null
#  name                 :text             not null
#  players              :jsonb            not null
#  settings             :jsonb            not null
#  started_at           :datetime
#  status               :integer          default("active"), not null
#  winner_names         :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  action_event_id      :bigint
#  game_template_id     :bigint
#  user_id              :bigint           not null
#
class GamePlay < ApplicationRecord
  DICE_MODES = { manual: 0, virtual: 1 }.freeze
  STATUSES = { active: 0, finished: 1, abandoned: 2 }.freeze

  enum :dice_mode, DICE_MODES
  enum :status, STATUSES

  belongs_to :user
  belongs_to :game_template, optional: true
  belongs_to :action_event, optional: true
  has_many :game_rolls, dependent: :destroy
  has_many :game_score_entries, dependent: :destroy

  validates :name, presence: true
  validates :client_uuid, presence: true, uniqueness: true

  scope :resumable, -> { active }

  def scoring
    settings["scoring"]&.to_sym || :individual
  end

  def win
    settings["win"]&.to_sym || :none
  end

  def dice
    settings["dice"]
  end

  def auto_advance?
    settings.key?("auto_advance") ? !!settings["auto_advance"] : true
  end

  def current_player
    players[current_player_index]
  end

  # Started client-side (even offline), so `started_at` and the first roll
  # may already exist by the time this hits the server. Only the ActionEvent
  # creation happens here - it needs `play_id` in `data` AT CREATION so Task
  # 283 (which fires on `event:action:added`) sees it in the same read and
  # skips the manual-logging prompt. See _scripts/plans/game_tracker_plan.md.
  def ensure_action_event!
    return action_event if action_event_id.present?

    evt = user.action_events.create!(
      name: "Game", notes: name, timestamp: started_at || Time.current,
      data: { players: blank_players_data, play_id: id }
    )
    update!(action_event_id: evt.id)
    evt
  end

  # The winner is never taken from the caller - it's derived from the scores
  # and the game's own win direction, every time. Nobody should have to
  # manually tell the app who won a game it already has the scores for.
  def finish!(final_scores:, started_at:, ended_at:, duration_minutes: nil)
    transaction do
      update!(
        status: :finished, final_scores: final_scores, winner_names: compute_winner_names(final_scores),
        started_at: started_at, ended_at: ended_at, duration_minutes: duration_minutes
      )
      sync_action_event!
    end
  end

  # No winner for :table (a single shared score has nothing to compare
  # against) or :none (the template says there's no score to judge by).
  def compute_winner_names(scores)
    return [] if win == :none || scoring == :table

    values = scores.values.compact
    return [] if values.empty?

    target = win == :low ? values.min : values.max
    scores.select { |_, v| v == target }.keys
  end

  def abandon!
    transaction do
      update!(status: :abandoned, ended_at: Time.current)
      sync_action_event!
    end
  end

  def duration
    return duration_minutes if duration_minutes.present?
    return nil unless started_at && ended_at

    ((ended_at - started_at) / 60).round
  end

  private

  def blank_players_data
    player_names.index_with { nil }
  end

  def player_names
    Array(players).map { |p| p["name"] || p[:name] }.compact
  end

  def sync_action_event!
    return unless action_event

    data = { play_id: id }
    case scoring
    when :teams
      data[:players] = blank_players_data
      data[:teams] = final_scores
    when :table
      data[:players] = blank_players_data
      data[:score] = final_scores.values.first
    else
      data[:players] = final_scores
    end
    data[:duration] = duration.to_s if duration.present?
    data[:abandoned] = true if abandoned?

    action_event.update!(notes: name, timestamp: started_at || action_event.timestamp, data: data)
  end
end
