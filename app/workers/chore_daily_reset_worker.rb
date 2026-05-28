# Runs once per day at the chore-day cutoff (3am local). Two jobs:
#   * Generate the Hot Picks for the new day — same set for all users.
#   * Reset any chore_streaks that missed a day so they read as zero.
class ChoreDailyResetWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 2

  LOW_PICK_COUNT = 5
  LOW_REWARD_MAX = 4            # "<5p" per spec — i.e. 1..4
  MEDIUM_PICK_COUNT = 2
  MEDIUM_REWARD_RANGE = (5..10)
  PREMIUM_RARE_CHANCE = 0.10
  LOW_RARE_CHANCE = 0.10
  LOW_RARE_MULT = 5.0
  STANDARD_MULT = 2.0

  def perform(day_iso = nil)
    day = day_iso.present? ? Date.parse(day_iso) : ChoreDay.current
    generate_hot_picks!(day)
    reset_stale_streaks!(day)
    archive_completed_one_offs!(day)
  end

  def generate_hot_picks!(day)
    return if ChoreHotPick.exists?(day_key: day)

    active = Chore.active.where(one_off: false)
    picks = []
    picks.concat(pick_for(active, LOW_PICK_COUNT) { |c| (1..LOW_REWARD_MAX).cover?(c.reward_pebbles) })
    picks.concat(pick_for(active, MEDIUM_PICK_COUNT) { |c| MEDIUM_REWARD_RANGE.cover?(c.reward_pebbles) })

    # 10% chance: take ONE of the chosen lows and bump it to 5x.
    rare_low = picks.find { |row| (1..LOW_REWARD_MAX).cover?(row[:chore].reward_pebbles) }
    if rare_low && rand < LOW_RARE_CHANCE
      rare_low[:multiplier] = LOW_RARE_MULT
    end

    # 10% chance: also flag one >Medium item at 2x.
    if rand < PREMIUM_RARE_CHANCE
      premium = active.where("reward_pebbles > ?", MEDIUM_REWARD_RANGE.max).order("RANDOM()").first
      picks << { chore: premium, multiplier: STANDARD_MULT } if premium
    end

    ChoreHotPick.transaction do
      picks.uniq { |p| p[:chore].id }.each do |row|
        ChoreHotPick.create!(day_key: day, chore_id: row[:chore].id, multiplier: row[:multiplier])
      end
    end

    broadcast_to_all_users!
  end

  # Streaks reset themselves implicitly via ChoreCompleter, but the UI
  # reads streak_count directly — so any streak whose last_completed_day
  # is older than yesterday needs to be zeroed before someone sees stale
  # numbers tomorrow.
  def reset_stale_streaks!(day)
    cutoff = day - 1
    ChoreStreak.where("last_completed_day < ?", cutoff).where("current_streak > 0").update_all(current_streak: 0)
  end

  # One-off chores stay visible the day they're completed; the next-day
  # reset archives anything that was completed at least once (by anyone).
  def archive_completed_one_offs!(day)
    completed_ids = ChoreCompletion.where(day_key: day - 1).select(:chore_id)
    Chore.active.where(one_off: true).where(id: completed_ids).update_all(archived_at: Time.current)
  end

  private

  def pick_for(scope, count)
    chores = scope.select { |c| yield(c) }
    chores.shuffle.first(count).map { |c| { chore: c, multiplier: STANDARD_MULT } }
  end

  def broadcast_to_all_users!
    User.where(id: Chore.distinct.pluck(:created_by_user_id)).find_each do |u|
      MonitorChannel.broadcast_to(u, {
        id: :chores,
        channel: :chores,
        timestamp: Time.current.to_i,
        data: { reason: :hot_picks_refreshed },
      })
    end
  rescue => e
    Rails.logger.warn("ChoreDailyResetWorker broadcast failed: #{e.message}")
  end
end
