# == Schema Information
#
# Table name: bowling_games
#
#  id            :integer          not null, primary key
#  absent        :boolean
#  card_point    :boolean          default(FALSE)
#  completed     :boolean          default(FALSE)
#  frame_details :jsonb
#  frames        :text
#  game_num      :integer
#  game_point    :boolean          default(FALSE)
#  handicap      :integer
#  position      :integer
#  score         :integer
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  bowler_id     :integer
#  set_id        :integer
#

class BowlingGame < ApplicationRecord
  attr_accessor :bowler_name, :league_id, :absent_score, :cached_frame_details

  belongs_to :set, class_name: "BowlingSet", inverse_of: :games
  belongs_to :bowler, inverse_of: :games
  has_many :new_frames, class_name: "BowlingFrame", dependent: :destroy

  validates :bowler_id, uniqueness: { scope: [:game_num, :set_id] }

  after_save {
    bowler.update(name: bowler_name) if bowler_name.present? && bowler&.name != bowler_name
    save_cached_details
  }

  before_validation { self.bowler_id ||= Bowler.create(league_id: set.league_id) }

  scope :absent, -> { where(absent: true) }
  scope :attended, -> { where(absent: [nil, false]) }

  def self.points
    where(game_point: true).count + where(card_point: true).count
  end

  def self.total_scores
    sum(:score) + sum(:handicap)
  end

  def perfect_game?
    score == 300
  end

  def league_id
    @new_attributes&.dig(:league_id) || set&.league_id || bowler&.league_id
  end

  def score = super.to_i

  def total_score
    score.to_i + handicap.to_i
  end

  def frames
    @frames ||= (super.to_s.split("|").presence || Array.new(10)).map { |roll| roll.to_s.chars }
  end

  def frames=(frames_arr)
    if frames_arr.is_a?(Hash)
      scores = frames_arr.map { |_idx, tosses|
        tosses.join
      }.join("|")

      super(scores)
    else
      super
    end
  end

  def frames_details=(params)
    @cached_frame_details = params
  end

  def frame_details
    details = new_frames.order(:frame_num)

    if details.length < 10
      details.to_a + (10 - details.length).times.map { BowlingFrame.new }
    else
      details
    end
  end

  def rolls_string
    frame_details.map(&:rolls).flatten.map { |r| r.nil? ? " " : r }.join
  end

  def output
    "(id:#{id})[#{game_num}]: #{rolls_string} #{score}"
  end

  private

  def save_cached_details
    (@cached_frame_details || {}).each_value { |frame_params|
      frame_attrs = BowlingScorer.params_to_attributes(frame_params)

      db_frame = new_frames.find_or_initialize_by(frame_num: frame_attrs[:frame_num])

      db_frame.update!(frame_attrs)
    }
    new_frames.reload
    if !completed? && (absent? || (new_frames.length == 10 && new_frames.all?(&:complete?)))
      CustomLog.log("(#{id}) Complete!")
      update(completed: true)
    elsif !completed?
      CustomLog.log("(#{id}) Incomplete! #{new_frames.map { |f| [f.id, f.complete?, f.rolls] }}")
    end
  end
end
