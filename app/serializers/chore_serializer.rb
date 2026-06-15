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
      id:                   chore.id,
      name:                 chore.name,
      short_name:           chore.short_name.presence || chore.name,
      icon:                 chore.icon,
      icon_kind:            icon_kind, # "emoji" | "image" | "svg" | "ti_icon" | "empty"
      aliases:              chore.aliases_array,
      notes_template:       chore.notes_template.to_s,
      notes:                chore.notes.to_s,
      reward_pebbles:       chore.reward_pebbles,
      reward_label:         chore.reward_label,
      # Daily target — when > 1, the card's progress ring fills as
      # `done_count_today / target_count` instead of flipping fully on
      # the first tap. `done` state stays binary (any tap counts) so
      # streaks, Today carryover, and Jil :completed are unchanged.
      target_count:         chore.target_count,
      progress_count:       done_count_today,
      # Cooldown / sharing-mode / hot-eligibility belong to the parent
      # for sub-chores — sub-chore taps credit the parent, so the
      # client must show parent's cooldown semantics to stay coherent.
      threshold_seconds:    effective_chore.threshold_seconds,
      cooldown_kind:        cooldown_kind, # "none" | "fixed" | "day_reset"
      one_off:              chore.one_off,
      sharing_mode:         effective_chore.sharing_mode,
      parent_chore_id:      chore.parent_chore_id,
      assigned_to_user_id:  chore.assigned_to_user_id,
      show_on_daily_view:   chore.show_on_daily_view,
      hot_eligibility:      chore.hot_eligibility,
      starts_on:            chore.starts_on&.iso8601,
      recurrence:           chore.recurrence || {},
      sort_order:           chore.sort_order,
      archived:             chore.archived?,
      marked_due_at:        chore.marked_due_at&.iso8601(3),
      marked_due_on:        marked_due_on,
      updated_at:           chore.updated_at.iso8601(3),
      # Per-viewer derived fields
      done_count_today:     done_count_today,
      last_completed_at:    last_completion&.completed_at&.iso8601(3),
      actor_username:       actor_username,
      last_actor_username:  last_actor_username,
      last_actor_anonymous: last_actor_anonymous?,
      hot_multiplier:       hot_multiplier,
      streak_multiplier:    streak_multiplier,
      today_visible:        today_visible?,
      due_today:            due_today?,
      on_dailies:           on_dailies?,
      scheduled_due_on:     scheduled_due_on&.iso8601,
    }
  end

  # Effective "due date" for sorting in Today's Scheduled section.
  # Resolution order: explicit marked_due → one-off starts_on → relative
  # / after_chore derived due day → most recent past matching day for
  # fixed-pattern schedules (capped at a 14-day lookback to mirror
  # `scheduled_or_carried?`). Nil for chores with no schedule frame
  # (e.g. daily_always with no marked override) so they sort to the bottom.
  def scheduled_due_on
    return ChoreDay.current(viewer, at: chore.marked_due_at) if chore.marked_due?
    return chore.starts_on if chore.one_off
    return nil unless chore.scheduled?

    last_before = last_completion_before_today&.day_key
    return chore.relative_due_on(viewer, last_completed_day: last_before) if chore.relative?
    return chore.after_chore_due_on_for(anchor_last_day) if chore.after_chore?

    most_recent_scheduled_day
  end

  # Whether the viewer has pinned this chore to their personal Dailies
  # section on Today. Independent of `today_visible?` — a chore stays
  # in the user's Dailies regardless of show_on_daily_view / schedule.
  def on_dailies?
    return ctx.daily_chore_ids.include?(chore.id) if ctx

    ChoreDaily.exists?(user_id: viewer.id, chore_id: chore.id)
  end

  # Date (YYYY-MM-DD) the mark resolves to in the viewer's chore-day
  # frame — what the Due Date form input should display. Lets the
  # client round-trip a stored datetime back to the same `<input type
  # ="date">` value the user originally picked.
  def marked_due_on
    return nil if chore.marked_due_at.nil?

    ChoreDay.current(viewer, at: chore.marked_due_at).iso8601
  end

  private

  # For sub-chores, inherited config (cooldown, sharing mode, household
  # scope) lives on the parent. `effective_chore` returns the parent
  # when this chore is a sub-chore, else the chore itself. Preloaded
  # via context's `includes(:parent_chore)`.
  def effective_chore
    @effective_chore ||= chore.parent_chore || chore
  end

  def icon_kind
    return :empty if chore.icon.blank?

    v = chore.icon.to_s.strip
    return :image   if v.start_with?("data:image/", "http://", "https://")
    return :svg     if v.start_with?("<svg")
    return :ti_icon if v.start_with?("ti-")

    :emoji
  end

  def cooldown_kind
    return :day_reset if effective_chore.threshold_seconds == Chore::THRESHOLD_DAY_RESET
    return :fixed     if effective_chore.threshold_seconds.to_i.positive?

    :none
  end

  def cooldown_scope_user_ids
    effective_chore.share_household? ? household_user_ids : [viewer.id]
  end

  def household_user_ids
    return @household_user_ids ||= ctx.household_user_ids if ctx

    @household_user_ids ||= viewer.chore_household_user_ids
  end

  def done_count_today
    if ctx
      return ctx.completions_today_by_sub_chore.fetch(chore.id, 0) if chore.sub_chore?

      return ctx.completions_today.fetch(chore.id, 0)
    end

    # All completions count — including ones recorded as "done by
    # someone outside the household" — so the card visually reads as
    # done. The ring color (set via last_actor_anonymous? below) is
    # what distinguishes who, if anyone, gets credit. Sub-chores look
    # up by sub_chore_id so each sibling's card tracks its own taps.
    column, value = chore.sub_chore? ? [:sub_chore_id, chore.id] : [:chore_id, chore.id]
    @done_count_today ||= ChoreCompletion
      .where(column => value, user_id: cooldown_scope_user_ids, day_key: day)
      .count
  end

  def last_completion
    if ctx
      return ctx.last_completion_by_sub_chore[chore.id] if chore.sub_chore?

      return ctx.last_completion_by_chore[chore.id]
    end

    column, value = chore.sub_chore? ? [:sub_chore_id, chore.id] : [:chore_id, chore.id]
    @last_completion ||= ChoreCompletion
      .where(column => value, user_id: cooldown_scope_user_ids)
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
    if ctx
      return ctx.last_completion_before_today_by_sub_chore[chore.id] if chore.sub_chore?

      return ctx.last_completion_before_today_by_chore[chore.id]
    end

    column, value = chore.sub_chore? ? [:sub_chore_id, chore.id] : [:chore_id, chore.id]
    @last_completion_before_today ||= ChoreCompletion
      .where(column => value, user_id: cooldown_scope_user_ids)
      .where(day_key: ...day)
      .order(completed_at: :desc).first
  end

  def actor_username
    return nil unless effective_chore.share_household?
    return nil if last_actor_anonymous?

    actor = actor_from_ctx
    return actor.username if actor && actor.id != viewer.id
    return nil if actor

    # Fallback when no preloaded context — single lookup. Anonymous
    # completions never get an actor, so the credited filter is fine
    # here too.
    column, value = chore.sub_chore? ? [:sub_chore_id, chore.id] : [:chore_id, chore.id]
    last = ChoreCompletion.credited
      .where(column => value, user_id: cooldown_scope_user_ids)
      .order(completed_at: :desc).first
    return nil if last.nil? || last.user_id == viewer.id

    User.where(id: last.user_id).pick(:username)
  end

  # Drives the per-actor accent color on Today / Grid cards. Returns
  # nil for anonymous-most-recent (grey ring via last_actor_anonymous?)
  # or when nothing's been completed yet.
  def last_actor_username
    return nil if last_actor_anonymous?

    actor = actor_from_ctx
    return actor.username if actor

    column, value = chore.sub_chore? ? [:sub_chore_id, chore.id] : [:chore_id, chore.id]
    last = ChoreCompletion.credited
      .where(column => value, user_id: cooldown_scope_user_ids)
      .order(completed_at: :desc).first
    return nil if last.nil?
    return viewer.username if last.user_id == viewer.id

    User.where(id: last.user_id).pick(:username)
  end

  def actor_from_ctx
    return nil unless ctx

    chore.sub_chore? ? ctx.completion_actor_by_sub_chore[chore.id] : ctx.completion_actor_by_chore[chore.id]
  end

  # True when the most recent completion of this chore — across the
  # cooldown scope — was anonymous. Drives the grey-ring treatment
  # so the card visually reads as done, but with no per-user color
  # attribution.
  def last_actor_anonymous?
    return @last_actor_anonymous_cached if defined?(@last_actor_anonymous_cached)

    last = last_completion
    @last_actor_anonymous_cached = last.present? && last.anonymous == true
  end

  def hot_multiplier
    return ctx.hot_picks[chore.id] if ctx

    @hot_multiplier ||= ChoreHotPick.lookup_for(day)[chore.id]
  end

  # Forecast of the streak-side multiplier this viewer would receive on
  # their NEXT completion of this chore — captures active ChoreStreakBonus
  # levels configured anywhere in the household, including the
  # chore-agnostic daily/weekly pebble thresholds. Returns 1 when none
  # apply. Capped at 5x to mirror ChoreCompleter#combined_streak_payout.
  def streak_multiplier
    return @streak_multiplier if defined?(@streak_multiplier)

    household_id = viewer.chore_household_id
    return @streak_multiplier = 1 if household_id.nil?

    # Streaks live on the parent — a sub-chore tap advances the parent's
    # streak — so a sub-chore card's forecast must read the parent's
    # streak row and parent-applicable bonuses, not the sub-chore's own.
    streak_chore_id = chore.parent_chore_id || chore.id
    bonuses = ChoreStreakBonus.active.where(chore_household_id: household_id).applicable_to(streak_chore_id)
    return @streak_multiplier = 1 if bonuses.empty?

    streak = ChoreStreak.find_by(user_id: viewer.id, chore_id: streak_chore_id)
    current = if streak&.last_completed_day.present? && streak.last_completed_day >= day - 1
      streak.current_streak.to_i
    else
      0
    end
    next_streak = current + 1
    combined = bonuses.inject(1) { |m, b| m * b.current_multiplier(viewer, for_streak: next_streak).to_i }
    @streak_multiplier = [combined, 5].min
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
    # marked_due is the "appears on Today" stamp — past or today shows,
    # future hides (lets the user pre-schedule a one-off or sub-chore
    # for a specific day without it cluttering Today now). The gate
    # is unconditional: a future-marked recurring chore stays off
    # Today even if its schedule would otherwise fire today.
    # Cleared by any ChoreCompletion (see ChoreCompletion#clear_chore_marked_due).
    if chore.marked_due?
      return chore.marked_due_at < ChoreDay.ends_at(day, viewer)
    end
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

  # Narrower than `today_visible?` — true only when the chore's schedule
  # actually fires on `day` (or it's a one-off that's currently on Today).
  # Carryover/overdue items are intentionally excluded so the client can
  # split the Today tab into "due today" vs "scheduled (overdue carryover)".
  def due_today?
    return false if chore.archived?
    return false if chore.assigned? && chore.assigned_to_user_id != viewer.id
    return false unless today_visible?

    # Marked-due lands in Today when the stamp falls within this
    # chore-day. Earlier marks fall through so the card surfaces as
    # overdue in the Scheduled section; future marks are already
    # filtered out by today_visible? above and never reach here.
    if chore.marked_due?
      return chore.marked_due_at >= ChoreDay.starts_at(day, viewer) &&
          chore.marked_due_at < ChoreDay.ends_at(day, viewer)
    end
    # One-offs are "due today" only on their starts_on date. Without a
    # starts_on (or past it), they fall through to Scheduled (Hourglass)
    # rather than implying today is the intended day.
    return chore.starts_on.present? && chore.starts_on == day if chore.one_off
    return false unless chore.scheduled?

    last_before = last_completion_before_today&.day_key
    if chore.relative?
      # `matches_day?` returns true for any date >= due_on for relative
      # schedules, which conflates due-today with overdue. Tighten to
      # strict equality so overdue relative chores land in Scheduled.
      due_on = chore.relative_due_on(viewer, last_completed_day: last_before)
      return due_on.present? && due_on == day
    end

    if chore.after_chore?
      # Strict "due today" = anchor's last credited completion + offset
      # equals today. Anchor done earlier with offset 0 (or any prior
      # date) is the carryover case → Scheduled section.
      a_last = anchor_last_day
      return false if a_last.nil?

      due_on = chore.after_chore_due_on_for(a_last)
      return due_on == day
    end

    chore.matches_day?(day, viewer, last_completed_day: last_before)
  end

  def anchor_last_day
    return nil unless chore.after_chore? && chore.anchor_chore_id.present?

    return ctx.anchor_last_day_by_chore[chore.id] if ctx.respond_to?(:anchor_last_day_by_chore)

    chore.lookup_anchor_last_day(viewer)
  end

  # Most recent day on or before `day` that this chore's fixed-pattern
  # schedule fires for the viewer. Bounded by a 14-day lookback so a
  # never-matching pattern doesn't scan forever. Memoized — `today_visible?`
  # (via `scheduled_or_carried?`) and `scheduled_due_on` both consult it.
  def most_recent_scheduled_day
    return @most_recent_scheduled_day if defined?(@most_recent_scheduled_day)

    last_before = last_completion_before_today&.day_key
    @most_recent_scheduled_day = ((day - 14)..day).reverse_each.find { |d|
      chore.matches_day?(d, viewer, last_completed_day: last_before)
    }
  end

  def scheduled_or_carried?(last_completed_day)
    return false unless chore.scheduled?
    return true  if chore.matches_day?(day, viewer, last_completed_day: last_completed_day, anchor_last_day: anchor_last_day)
    return false if chore.relative? || chore.after_chore?

    last_scheduled_day = most_recent_scheduled_day
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
