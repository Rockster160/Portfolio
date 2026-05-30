# Orchestrates a Chore being marked complete by a User:
#   * checks the per-user threshold window (skipped completions are
#     recorded but pay nothing and do NOT reset the timer)
#   * applies hot-pick multiplier
#   * applies user multipliers (daily/weekly/streak)
#   * updates the ChoreStreak row
#   * evaluates achievements
#   * broadcasts a Monitor update so other devices refresh
class ChoreCompleter
  Result = Struct.new(:completion, :awarded, :skipped_reason, keyword_init: true) {
    def skipped? = !!skipped_reason
  }

  def initialize(chore, user, at: Time.current)
    @chore = chore
    @user = user
    @at = at
    @day = ChoreDay.current(user, at: at)
  end

  def call
    completion = ChoreCompletion.transaction do
      record = build_completion
      apply_threshold!(record)
      apply_payout!(record) unless record.payout_skipped
      record.save!
      sync_streak!(record) unless record.payout_skipped
      record
    end

    awards = evaluate_achievements(completion)
    broadcast!
    Result.new(
      completion: completion,
      awarded: awards,
      skipped_reason: completion.skipped_reason,
    )
  end

  private

  attr_reader :chore, :user, :at, :day

  def build_completion
    ChoreCompletion.new(
      chore: chore,
      user: user,
      completed_at: at,
      day_key: day,
      base_pebbles: chore.reward_pebbles,
      hot_multiplier: 1.0,
      total_multiplier: 1.0,
      paid_pebbles: 0,
      metadata: { chore_name: chore.name, short_name: chore.display_short_name },
    )
  end

  # Threshold check: if the chore has a threshold and SOMEBODY has been
  # PAID within that window, skip payout for this tap. Scope:
  #   :household — looks across everyone in the share group
  #   :personal  — this user only
  #   :assigned  — assignee only (same as :personal in practice)
  # The timer never resets — we look back from `at` to find the last
  # PAID completion among the relevant user(s).
  def apply_threshold!(record)
    return if chore.threshold_seconds.blank? || chore.threshold_seconds.to_i.zero?

    scope_user_ids = chore.cooldown_scope_user_ids(user)
    last_paid = ChoreCompletion
      .where(user_id: scope_user_ids, chore_id: chore.id, payout_skipped: false)
      .where(completed_at: ...at)
      .order(completed_at: :desc).first
    return if last_paid.blank?

    if chore.cooldown_until_day_reset?
      # Day-reset cooldown: blocked only if a paid completion already
      # exists in the same ChoreDay window. Once we cross 4am (or
      # whatever ChoreDay::CUTOFF_HOURS is), the cooldown is gone.
      return unless last_paid.day_key == day

      record.payout_skipped = true
      record.skipped_reason = "Cooldown — resets at end of day"
      return
    end

    window_end = last_paid.completed_at + chore.threshold_seconds.seconds
    return unless at < window_end

    record.payout_skipped = true
    remaining = (window_end - at).to_i
    record.skipped_reason = "Cooldown — next payout in #{format_seconds(remaining)}"
  end

  def apply_payout!(record)
    hot = ChoreHotPick.find_by(day_key: day, chore_id: chore.id)
    hot_multiplier = hot&.multiplier || 1.0

    streak_count = current_streak_count + 1 # this completion advances it
    user_multiplier = combined_user_multiplier(streak_count)
    total = (hot_multiplier * user_multiplier).round(3)
    base = chore.reward_pebbles
    paid = (base * total).round

    record.hot_multiplier = hot_multiplier
    record.total_multiplier = total
    record.paid_pebbles = paid
    record.metadata = record.metadata.merge(
      user_multiplier: user_multiplier,
      streak_count_after: streak_count,
      hot_pick: hot.present?,
    )
  end

  def combined_user_multiplier(streak_count)
    multipliers = user.chore_multipliers.active.where(chore_id: chore.id)
    return 1.0 if multipliers.empty?

    # Multiplicative across active multipliers, capped at 5x to avoid
    # runaway combos.
    combined = multipliers.inject(1.0) { |m, mx|
      m * mx.current_multiplier(user, for_streak: streak_count)
    }
    [combined, 5.0].min
  end

  def current_streak_count
    streak = ChoreStreak.find_by(user_id: user.id, chore_id: chore.id)
    return 0 if streak.blank? || streak.last_completed_day.blank?
    return streak.current_streak if streak.last_completed_day == day
    return streak.current_streak if streak.last_completed_day == day - 1

    0
  end

  def sync_streak!(record)
    streak = ChoreStreak.find_or_initialize_by(user_id: user.id, chore_id: chore.id)
    last = streak.last_completed_day
    if last.nil? || last < day - 1
      streak.current_streak = 1
    elsif last == day - 1
      streak.current_streak = streak.current_streak.to_i + 1
    end
    streak.longest_streak = [streak.longest_streak.to_i, streak.current_streak].max
    streak.last_completed_day = day
    streak.save!
  end

  def evaluate_achievements(completion)
    # One query for all active achievements, one for previously-earned
    # ids — instead of N+1 EXISTS checks. The per-achievement evaluate
    # still queries its own metric (completions count, streaks, etc.),
    # but that's bounded by the number of UNEARNED active achievements.
    candidates = ChoreAchievement.active.to_a
    earned_ids = UserChoreAchievement
      .where(user_id: user.id, chore_achievement_id: candidates.map(&:id))
      .pluck(:chore_achievement_id).to_set
    earned = []
    candidates.each do |achievement|
      next if earned_ids.include?(achievement.id)
      next unless achievement.evaluate(user)

      award = UserChoreAchievement.create!(
        user: user,
        chore_achievement: achievement,
        earned_at: Time.current,
        awarded_pebbles: achievement.reward_pebbles,
        chore_completion: completion,
      )
      earned << award
    end
    earned
  end

  def broadcast!
    ChoreBroadcaster.broadcast_changes!(user, chore)
  end

  # Two-unit, integer-only duration formatter. NEVER produces decimals.
  #   90061s   → "1d 1h"
  #   5421s    → "1h 30m"
  #   125s     → "2m" (sub-minute precision dropped per spec — no seconds shown)
  #   30s      → "<1m"
  def format_seconds(seconds)
    s = seconds.to_i
    return "<1m" if s < 60

    days  = s / 86_400
    hours = (s % 86_400) / 3600
    mins  = (s % 3600)   / 60
    parts = []
    if days > 0
      parts << "#{days}d"
      parts << "#{hours}h" if hours > 0
    elsif hours > 0
      parts << "#{hours}h"
      parts << "#{mins}m" if mins > 0
    else
      parts << "#{mins}m"
    end
    parts.first(2).join(" ")
  end
end
