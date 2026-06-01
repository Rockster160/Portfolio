# Canonical chore JSON shape — the single payload that powers every
# client view (Grid, Today, Hot strip), every endpoint that touches a
# chore (sync, state, create, update, complete), and any external
# consumer (Jil, API).
#
# Server is responsible for the read-derived fields (`done_count_today`,
# `last_completed_at`, `today_visible`, `hot_multiplier`, ...). The
# client templates are pure functions of this payload — no extra
# round-trips, no second-guessing visibility rules.
#
# Build pattern is "lazy single instance" — instantiate once with
# preloaded context (day, household ids, hot picks lookup), then call
# `.as_json` to emit. For bulk page rendering, build a
# ChoreSerializerContext once and reuse it across N serializers.
class ChoreSerializer
  attr_reader :chore, :viewer, :day, :ctx

  def initialize(chore, viewer:, ctx: nil, day: nil)
    @chore = chore
    @viewer = viewer
    @day = day || (ctx&.day) || ChoreDay.current(viewer)
    @ctx = ctx
  end

  def as_json(*)
    {
      id:                  chore.id,
      name:                chore.name,
      short_name:          chore.short_name.presence || chore.name,
      icon:                chore.icon,
      icon_kind:           icon_kind, # "emoji" | "image" | "svg" | "empty"
      aliases:             chore.aliases_array,
      reward_pebbles:      chore.reward_pebbles,
      reward_label:        chore.reward_label,
      threshold_seconds:   chore.threshold_seconds,
      cooldown_kind:       cooldown_kind, # "none" | "fixed" | "day_reset"
      one_off:             chore.one_off,
      sharing_mode:        chore.sharing_mode,
      assigned_to_user_id: chore.assigned_to_user_id,
      show_on_daily_view:  chore.show_on_daily_view,
      starts_on:           chore.starts_on&.iso8601,
      recurrence:          chore.recurrence || {},
      sort_order:          chore.sort_order,
      archived:            chore.archived?,
      updated_at:          chore.updated_at.iso8601(3),
      # Per-viewer derived fields
      done_count_today:    done_count_today,
      last_completed_at:   last_completion&.completed_at&.iso8601(3),
      actor_username:      actor_username,
      last_actor_username: last_actor_username,
      hot_multiplier:      hot_multiplier,
      streak_multiplier:   streak_multiplier,
      today_visible:       today_visible?,
    }
  end

  private

  def icon_kind
    return :empty if chore.icon.blank?

    v = chore.icon.to_s.strip
    return :image if v.start_with?("data:image/", "http://", "https://")
    return :svg   if v.start_with?("<svg")

    :emoji
  end

  def cooldown_kind
    return :day_reset if chore.threshold_seconds == Chore::THRESHOLD_DAY_RESET
    return :fixed     if chore.threshold_seconds.to_i.positive?

    :none
  end

  def cooldown_scope_user_ids
    chore.share_household? ? household_user_ids : [viewer.id]
  end

  def household_user_ids
    return @household_user_ids ||= ctx.household_user_ids if ctx

    @household_user_ids ||= Chore.household_user_ids_for(viewer.id)
  end

  def done_count_today
    return ctx.completions_today.fetch(chore.id, 0) if ctx

    @done_count_today ||= ChoreCompletion
      .where(chore_id: chore.id, user_id: cooldown_scope_user_ids, day_key: day)
      .count
  end

  def last_completion
    return ctx.last_completion_by_chore[chore.id] if ctx

    @last_completion ||= ChoreCompletion
      .where(chore_id: chore.id, user_id: cooldown_scope_user_ids)
      .order(completed_at: :desc).first
  end

  # State of the world AS-OF the start of `day` — the most recent
  # completion (paid or skipped) strictly before today. Drives
  # `today_visible?` so the answer is invariant to anything that
  # happens during `day`: completing a chore today must not change
  # whether it's on Today. Payment status is intentionally NOT a
  # visibility input — a skipped completion and a paid completion
  # both represent the user acting on the chore.
  def last_completion_before_today
    return ctx.last_completion_before_today_by_chore[chore.id] if ctx

    @last_completion_before_today ||= ChoreCompletion
      .where(chore_id: chore.id, user_id: cooldown_scope_user_ids)
      .where(day_key: ...day)
      .order(completed_at: :desc).first
  end

  def actor_username
    return nil unless chore.share_household?

    actor = ctx&.completion_actor_by_chore&.[](chore.id)
    return actor.username if actor && actor.id != viewer.id
    return nil if actor

    # Fallback when no preloaded context — single lookup.
    last = last_completion
    return nil if last.nil? || last.user_id == viewer.id

    User.where(id: last.user_id).pick(:username)
  end

  # Username of whoever most recently completed the chore — regardless
  # of sharing mode. Drives the per-user accent color on Today / Grid
  # cards so a Rocco-checked chore reads visually different from a
  # Chelsea-checked one. Returns nil when nobody's completed it yet.
  def last_actor_username
    actor = ctx&.completion_actor_by_chore&.[](chore.id)
    return actor.username if actor

    last = last_completion
    return nil if last.nil?
    return viewer.username if last.user_id == viewer.id

    User.where(id: last.user_id).pick(:username)
  end

  def hot_multiplier
    return ctx.hot_picks[chore.id] if ctx

    @hot_multiplier ||= ChoreHotPick.lookup_for(day)[chore.id]
  end

  # Forecast of the user-side multiplier this viewer would receive on
  # their NEXT completion of this chore — captures active daily/weekly/
  # streak multipliers configured anywhere in the household for this
  # chore. Returns 1.0 when no multipliers apply. Capped at 5x to
  # mirror ChoreCompleter#combined_user_multiplier.
  def streak_multiplier
    return @streak_multiplier if defined?(@streak_multiplier)

    household_ids = ctx&.household_user_ids || Chore.household_user_ids_for(viewer.id)
    multipliers = ChoreMultiplier.active.where(user_id: household_ids, chore_id: chore.id)
    return @streak_multiplier = 1.0 if multipliers.empty?

    streak = ChoreStreak.find_by(user_id: viewer.id, chore_id: chore.id)
    current = (streak&.last_completed_day.present? && streak.last_completed_day >= day - 1) ?
                streak.current_streak.to_i : 0
    next_streak = current + 1
    combined = multipliers.inject(1.0) { |m, mx| m * mx.current_multiplier(viewer, for_streak: next_streak) }
    @streak_multiplier = [combined, 5.0].min
  end

  # today_visible? answers ONE question: would this chore have been on
  # Today at the 4am rollover, before any of today's completions
  # existed? Every input is the day-start state —
  # `last_completion_before_today` for the cooldown gate and
  # completion_days strictly before `day` for carryover. Today's own
  # completions are intentionally not consulted, so completing a
  # Grid-only chore never adds it to Today and completing a Today
  # chore never removes it. Carryovers that get checked off today
  # stay carryovers on Today for the rest of the day.
  def today_visible?
    return false if chore.archived?
    # An explicit assignee owns Today exclusively — personal+assigned is
    # already hidden upstream via `visible_to_user`, but household+assigned
    # is still grid-visible to the household, so the Today gate lives here.
    return false if chore.assigned? && chore.assigned_to_user_id != viewer.id
    return true  if chore.one_off
    return true  if chore.daily_always?
    return false if chore.show_on_daily_view.to_sym == :never

    last_before = last_completion_before_today
    scheduled = scheduled_or_carried?(last_before&.day_key)
    available = chore.cooldown_elapsed?(viewer, last_completion: last_before)

    case chore.show_on_daily_view.to_sym
    when :always                       then true
    when :when_scheduled               then scheduled
    when :when_available               then available
    when :when_scheduled_and_available then scheduled || available
    else false
    end
  end

  def scheduled_or_carried?(last_completed_day)
    return false unless chore.scheduled?
    return true  if chore.matches_day?(day, viewer, last_completed_day: last_completed_day)
    return false if chore.relative?

    last_scheduled_day = ((day - 14)..(day - 1)).reverse_each.find { |d|
      chore.matches_day?(d, viewer, last_completed_day: last_completed_day)
    }
    return false if last_scheduled_day.blank?

    # Carryover means "scheduled in the past and not completed since"
    # — and "since" is bounded by yesterday, not today. A completion
    # made today must not retroactively cancel the chore's place on
    # Today; that's what made it a carryover in the first place.
    if ctx&.completion_days_before_today_by_chore
      done_set = ctx.completion_days_before_today_by_chore.fetch(chore.id, Set.new)
      done_set.none? { |d| d >= last_scheduled_day && d < day }
    else
      ChoreCompletion
        .where(user_id: viewer.id, chore_id: chore.id, day_key: last_scheduled_day..(day - 1))
        .none?
    end
  end
end
