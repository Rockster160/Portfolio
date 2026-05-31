# == Schema Information
#
# Table name: chore_achievements
#
#  id             :bigint           not null, primary key
#  active         :boolean          default(TRUE), not null
#  config         :jsonb            not null
#  description    :text
#  image_url      :text
#  kind           :integer          default("total_completions"), not null
#  name           :string           not null
#  reward_link    :text
#  reward_pebbles :integer          default(0), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
class ChoreAchievement < ApplicationRecord
  KINDS = {
    total_completions:      0,
    chore_completion_count: 1,
    chore_streak_days:      2,
    total_pebbles_earned:   3,
  }.freeze

  enum :kind, KINDS, default: :total_completions

  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :user_chore_achievements, dependent: :destroy

  validates :name, presence: true

  scope :active, -> { where(active: true) }
  # Achievements with a creator are scoped to the creator's household;
  # rows with a null creator are legacy/global and remain visible to all.
  scope :visible_to_user, ->(user_id) {
    household_ids = Chore.household_user_ids_for(user_id)
    where("created_by_user_id IS NULL OR created_by_user_id IN (?)", household_ids)
  }

  # Has this user earned the achievement (based on current data)?
  def evaluate(user)
    case kind.to_sym
    when :total_completions
      target = config["count"].to_i
      ChoreCompletion.where(user_id: user.id).count >= target
    when :chore_completion_count
      target = config["count"].to_i
      chore_id = config["chore_id"].to_i
      ChoreCompletion.where(user_id: user.id, chore_id: chore_id).count >= target
    when :chore_streak_days
      target = config["days"].to_i
      chore_id = config["chore_id"].to_i
      streak = ChoreStreak.find_by(user_id: user.id, chore_id: chore_id)
      (streak&.current_streak || 0) >= target
    when :total_pebbles_earned
      target = config["pebbles"].to_i
      ChoreCompletion.where(user_id: user.id).sum(:paid_pebbles) >= target
    else
      false
    end
  end
end
