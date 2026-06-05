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

  def perform(day_iso=nil)
    day = day_iso.present? ? Date.parse(day_iso) : ChoreDay.current
    generate_hot_picks!(day)
    reset_stale_streaks!(day)
    archive_completed_one_offs!(day)
  end

  def generate_hot_picks!(day)
    return if ChoreHotPick.exists?(day_key: day)

    available = Chore.active.where(one_off: false).to_a
    # Per-chore override: :never excludes entirely; the rest fall through
    # to reject_not_hot_eligible which still applies the unscheduled /
    # due-today / overdue gating.
    available = available.reject(&:hot_never?)
    due_today_ids = scheduled_due_today_ids(available, day)
    available = reject_not_hot_eligible(available, day)
    available = reject_on_cooldown(available, day)
    picks = []
    picks.concat(pick_for(available, LOW_PICK_COUNT, due_today_ids) { |c| (1..LOW_REWARD_MAX).cover?(c.reward_pebbles) })
    picks.concat(pick_for(available, MEDIUM_PICK_COUNT, due_today_ids) { |c| MEDIUM_REWARD_RANGE.cover?(c.reward_pebbles) })

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

    ChoreBroadcaster.broadcast_hot_picks_refreshed!
  end

  # Streaks reset themselves implicitly via ChoreCompleter, but the UI
  # reads streak_count directly — so any streak whose last_completed_day
  # is older than yesterday needs to be zeroed before someone sees stale
  # numbers tomorrow.
  def reset_stale_streaks!(day)
    cutoff = day - 1
    ChoreStreak.where(last_completed_day: ...cutoff).where("current_streak > 0").update_all(current_streak: 0)
  end

  # One-off chores stay visible the day they're completed; the next-day
  # reset archives anything that was completed at least once (by anyone).
  def archive_completed_one_offs!(day)
    completed_ids = ChoreCompletion.where(day_key: day - 1).select(:chore_id)
    Chore.active.where(one_off: true).where(id: completed_ids).update_all(archived_at: Time.current)
  end

  # Pick + persist a replacement Hot Pick after one is rotated out.
  # Reuses the same eligibility / cooldown / weighting rules as the
  # daily refresh so manual rotations match the morning batch's odds.
  # Tries the removed pick's reward band first; falls back to any
  # band if that bracket is empty. Returns the new ChoreHotPick row,
  # or nil if no candidates remain. Caller owns the transaction +
  # broadcast.
  def rotate!(day:, excluded_chore_id:, multiplier:)
    band = reward_band_for(excluded_chore_id)
    pick_replacement(day: day, band: band, multiplier: multiplier, excluded_id: excluded_chore_id) ||
      pick_replacement(day: day, band: :any, multiplier: multiplier, excluded_id: excluded_chore_id)
  end

  private

  # Weighted random pick using cumulative-sum sampling. Every eligible
  # chore is in the pool; their per-chore weights decide the odds.
  # Floats and arbitrarily large weights are both fine. To pick N
  # distinct items, we re-sample after removing the previous winner —
  # so a 1.5x weight stays 1.5x even on the third pick. New weight
  # modifiers (priority, age, streak proximity, ...) plug in by
  # editing `weight_for` only; the sampler stays untouched.
  TODAY_DUE_WEIGHT = 1.5
  BASELINE_WEIGHT  = 1.0
  def pick_for(scope, count, due_today_ids=Set.new, &)
    chores = scope.select(&)
    return [] if chores.empty?

    weighted_sample(chores, count) { |c| weight_for(c, due_today_ids) }
      .map { |c| { chore: c, multiplier: STANDARD_MULT } }
  end

  def weight_for(chore, due_today_ids)
    due_today_ids.include?(chore.id) ? TODAY_DUE_WEIGHT : BASELINE_WEIGHT
  end

  # Cumulative-sum weighted random sample WITHOUT replacement. O(N×K)
  # for K picks from N items — fine for the few-from-few hot-pick case;
  # use a heap / Efraimidis–Spirakis variant if this ever needs to
  # scale into the thousands.
  def weighted_sample(items, count)
    pool = items.map { |i| [i, yield(i).to_f] }.reject { |(_, w)| w <= 0 }
    picks = []
    while picks.size < count && pool.any?
      total = pool.sum { |(_, w)| w }
      break if total <= 0

      r = rand * total
      cum = 0.0
      idx = pool.find_index { |(_, w)| (cum += w) >= r } || (pool.size - 1)
      picks << pool[idx][0]
      pool.delete_at(idx)
    end
    picks
  end

  def pick_replacement(day:, band:, multiplier:, excluded_id:)
    pool = candidate_pool(day, excluded_id: excluded_id)
    due_today_ids = scheduled_due_today_ids(pool, day)
    pool = filter_by_band(pool, band)
    return nil if pool.empty?

    candidate = weighted_sample(pool, 1) { |c| weight_for(c, due_today_ids) }.first
    return nil unless candidate

    ChoreHotPick.create!(day_key: day, chore_id: candidate.id, multiplier: multiplier)
  end

  def candidate_pool(day, excluded_id:)
    pool = Chore.active.where(one_off: false).to_a
    pool = pool.reject(&:hot_never?)
    pool = pool.reject { |c| c.id == excluded_id } if excluded_id
    taken = ChoreHotPick.for_day(day).pluck(:chore_id).to_set
    pool = pool.reject { |c| taken.include?(c.id) }
    pool = reject_not_hot_eligible(pool, day)
    reject_on_cooldown(pool, day)
  end

  def filter_by_band(pool, band)
    case band
    when :low    then pool.select { |c| (1..LOW_REWARD_MAX).cover?(c.reward_pebbles) }
    when :medium then pool.select { |c| MEDIUM_REWARD_RANGE.cover?(c.reward_pebbles) }
    when :high   then pool.select { |c| c.reward_pebbles > MEDIUM_REWARD_RANGE.max }
    else pool
    end
  end

  def reward_band_for(chore_id)
    chore = Chore.find_by(id: chore_id)
    return :any unless chore
    return :low    if (1..LOW_REWARD_MAX).cover?(chore.reward_pebbles)
    return :medium if MEDIUM_REWARD_RANGE.cover?(chore.reward_pebbles)

    :high
  end

  # Bulk-compute the subset of `chores` that are due (matches_day?)
  # on `day`. Relative-recurrence chores are per-user and can't be
  # globally resolved, so they're excluded.
  def scheduled_due_today_ids(chores, day)
    chores.each_with_object(Set.new) { |c, set|
      next unless c.scheduled?
      next if c.relative?

      set << c.id if c.matches_day?(day)
    }
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
    # :when_scheduled chores must have an actual schedule and either
    # be due today or overdue — never unscheduled fillers. due_today /
    # overdue are already gated on schedule below; only unscheduled
    # needs the explicit exclusion.
    unscheduled = unscheduled.reject(&:hot_when_scheduled?)

    # Bulk-load every completion day in the look-back window in one query
    # — avoids per-chore .exists? lookups in the carryover branch.
    candidates = future_only
    completion_days = ChoreCompletion
      .where(chore_id: candidates.map(&:id), day_key: (day - HOT_OVERDUE_WINDOW)..day)
      .distinct.pluck(:chore_id, :day_key)
      .group_by(&:first)
      .transform_values { |entries| entries.to_set(&:last) }

    overdue = candidates.select { |c|
      last_scheduled = ((day - HOT_OVERDUE_WINDOW)..(day - 1)).reverse_each.find { |d| c.matches_day?(d) }
      next false if last_scheduled.nil?

      done = completion_days.fetch(c.id, Set.new)
      done.none? { |d| d.between?(last_scheduled, day) }
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
end
