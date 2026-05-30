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

    available = Chore.active.where(one_off: false).to_a
    available = reject_not_hot_eligible(available, day)
    available = reject_on_cooldown(available, day)
    picks = []
    picks.concat(pick_for(available, LOW_PICK_COUNT) { |c| (1..LOW_REWARD_MAX).cover?(c.reward_pebbles) })
    picks.concat(pick_for(available, MEDIUM_PICK_COUNT) { |c| MEDIUM_REWARD_RANGE.cover?(c.reward_pebbles) })

    # 10% chance: take ONE of the chosen lows and bump it to 5x.
    rare_low = picks.find { |row| (1..LOW_REWARD_MAX).cover?(row[:chore].reward_pebbles) }
    if rare_low && rand < LOW_RARE_CHANCE
      rare_low[:multiplier] = LOW_RARE_MULT
    end

    # 10% chance: also flag one >Medium item at 2x.
    if rand < PREMIUM_RARE_CHANCE
      premium = available.select { |c| c.reward_pebbles > MEDIUM_REWARD_RANGE.max }.sample
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

  # Hot-pick eligibility, applied BEFORE cooldown rejection:
  #   * Unscheduled chores (freq: :never)        — always eligible
  #   * Scheduled chores due today               — eligible
  #   * Scheduled chores whose last scheduled
  #     day is in the past with no completion
  #     since (i.e. overdue / carryover)         — eligible
  # Relative-recurrence chores are per-user; they're skipped here since
  # hot picks are a global set.
  HOT_OVERDUE_WINDOW = 14
  def reject_not_hot_eligible(chores, day)
    scheduled, unscheduled = chores.partition(&:scheduled?)
    relative, fixed_scheduled = scheduled.partition(&:relative?)
    due_today, future_only = fixed_scheduled.partition { |c| c.matches_day?(day) }

    # Bulk-load every completion day in the look-back window in one query
    # — avoids per-chore .exists? lookups in the carryover branch.
    candidates = future_only
    completion_days = ChoreCompletion
      .where(chore_id: candidates.map(&:id), day_key: (day - HOT_OVERDUE_WINDOW)..day)
      .distinct.pluck(:chore_id, :day_key)
      .group_by(&:first)
      .transform_values { |entries| entries.map(&:last).to_set }

    overdue = candidates.select { |c|
      last_scheduled = ((day - HOT_OVERDUE_WINDOW)..(day - 1)).reverse_each.find { |d| c.matches_day?(d) }
      next false if last_scheduled.nil?

      done = completion_days.fetch(c.id, Set.new)
      done.none? { |d| d >= last_scheduled && d <= day }
    }

    _ = relative # intentionally excluded; per-user dueness can't be globalised
    unscheduled + due_today + overdue
  end

  # Drop chores whose cooldown still blocks a paid completion. A single
  # paid completion anywhere in the chore's user scope disqualifies it
  # — being a Hot Pick on a chore nobody can earn on right now defeats
  # the point. One bulk SQL pass instead of per-chore checks.
  def reject_on_cooldown(chores, day, now: Time.current)
    threshold_chores = chores.reject { |c| c.threshold_seconds.to_i.zero? }
    return chores if threshold_chores.empty?

    fixed_thresholds = threshold_chores.reject(&:cooldown_until_day_reset?)
      .map { |c| c.threshold_seconds.to_i }
    fixed_window = fixed_thresholds.max || 0

    rows = ChoreCompletion
      .where(chore_id: threshold_chores.map(&:id), payout_skipped: false)
      .where("completed_at >= :ts OR day_key = :day", ts: now - fixed_window.seconds, day: day)
      .order(completed_at: :desc)
      .pluck(:chore_id, :completed_at, :day_key)

    last_by_chore = {}
    rows.each { |chore_id, ts, dk| last_by_chore[chore_id] ||= [ts, dk] }

    chores.reject { |chore|
      next false if chore.threshold_seconds.to_i.zero?

      last = last_by_chore[chore.id]
      next false if last.nil?

      ts, dk = last
      if chore.cooldown_until_day_reset?
        dk == day
      else
        (ts + chore.threshold_seconds.seconds) > now
      end
    }
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
