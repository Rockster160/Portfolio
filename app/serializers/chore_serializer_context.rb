# Bulk-loaded shared state for ChoreSerializer. Built ONCE per request
# (or once per `/sync` call), then passed into each individual
# ChoreSerializer so the per-chore JSON build is O(1) DB-wise.
#
# `for_user` is the high-level entry point — give it the viewer, get
# back a context preloaded for all of that user's accessible chores.
class ChoreSerializerContext
  attr_reader :viewer, :day, :hot_picks,
    :completions_today, :last_completion_by_chore,
    :last_completion_before_today_by_chore,
    :completion_actor_by_chore, :completion_days_by_chore,
    :completion_days_before_today_by_chore,
    :anchor_last_day_by_chore,
    :household_user_ids, :daily_chore_ids,
    :household_icons_by_id,
    # Sub-chore parallels: keyed by sub_chore_id rather than chore_id.
    # Sub-chore cards must look at completions WHERE sub_chore_id =
    # sub.id (the parent's chore_id rollup would include every other
    # sibling's work).
    :last_completion_by_sub_chore,
    :last_completion_before_today_by_sub_chore,
    :completion_actor_by_sub_chore,
    :completions_today_by_sub_chore

  def self.for_user(viewer, day: nil)
    new(viewer: viewer, day: day || ChoreDay.current(viewer))
  end

  def initialize(viewer:, day:)
    @viewer = viewer
    @day = day
    @household_user_ids = viewer.chore_household_user_ids
    # Preload parent_chore so sub-chores can read inherited config
    # (threshold, sharing_mode, cooldown_kind) without N+1 reloads.
    chores = viewer.accessible_chores.includes(:parent_chore).to_a
    @chores_by_id = chores.index_by(&:id)
    @chore_ids = chores.map(&:id)
    @household_chore_ids = chores.select(&:share_household?).map(&:id)
    @personal_chore_ids  = @chore_ids - @household_chore_ids
    @sub_chore_ids = chores.select(&:sub_chore?).map(&:id)
    preload!
  end

  def serialize_all(chores)
    chores.map { |c| ChoreSerializer.new(c, viewer: viewer, ctx: self).as_json }
  end

  def household_icon_for(id)
    @household_icons_by_id[id]
  end

  private

  def preload!
    @hot_picks = ChoreHotPick.lookup_for(day)
    @daily_chore_ids = ChoreDaily.for_user(viewer).pluck(:chore_id).to_set
    # Preload every household icon once so the serializer's
    # hicon:<id> → image_data resolve is O(1) per chore. Household is
    # tiny (~10s of icons) so we bulk-load the whole set rather than
    # scanning chore icon strings to build a targeted IN(...) list.
    @household_icons_by_id = if viewer.chore_household_id
      HouseholdIcon.where(chore_household_id: viewer.chore_household_id).index_by(&:id)
    else
      {}
    end

    @last_completion_by_chore = bulk_last_completion(@personal_chore_ids, [viewer.id])
      .merge(bulk_last_completion(@household_chore_ids, household_user_ids))

    # Today visibility is computed AS-OF day start: every input must
    # be the state of the world before today_visible could be
    # disturbed by today's own completions. Payment status is
    # explicitly NOT a visibility input — a skipped tap and a paid
    # tap both represent "the user acted on this chore." So this is
    # the most recent completion (paid or skipped) strictly before
    # `day`.
    @last_completion_before_today_by_chore =
      bulk_last_completion_before_day(@personal_chore_ids, [viewer.id])
        .merge(bulk_last_completion_before_day(@household_chore_ids, household_user_ids))

    @completion_actor_by_chore = bulk_last_actor(@household_chore_ids, household_user_ids)

    # done_count_today is the visible "x of n done" stat — ALL
    # completions, including ones recorded as "done by someone
    # outside the household", count here so the card reads as done.
    # The grey-ring treatment (last_actor_anonymous) is what tells
    # the user nobody in the household got credit.
    @completions_today = ChoreCompletion
      .where(day_key: day, chore_id: @personal_chore_ids, user_id: viewer.id)
      .group(:chore_id).count
      .merge(
        ChoreCompletion
          .where(day_key: day, chore_id: @household_chore_ids, user_id: household_user_ids)
          .group(:chore_id).count,
      )
    # Carryover input for today_visible?: was the chore completed
    # since its last scheduled day? Household chores answer
    # household-wide; personal chores stay scoped to the viewer.
    # Anonymous completions count — the work was done.
    personal_days = bulk_completion_days(@personal_chore_ids, [viewer.id])
    household_days = bulk_completion_days(@household_chore_ids, household_user_ids)
    @completion_days_by_chore = personal_days.merge(household_days)

    # Same shape, but excluding today — used by the carryover branch
    # of today_visible? so a completion today can't flip the chore
    # off Today by being newer than the last-scheduled-day.
    @completion_days_before_today_by_chore = @completion_days_by_chore
      .transform_values { |days| days.reject { |d| d >= day }.to_set }

    # :after_chore chores anchor on another chore's most recent
    # credited completion (anonymous excluded — see locked rules in
    # the plan). For every chore B in the household that follows some
    # A, we want the max(day_key) of A's credited completions under
    # B's cooldown user scope, in one IN(...) GROUP BY. Keyed by B's
    # id so the serializer can look it up O(1).
    @anchor_last_day_by_chore = bulk_anchor_last_days

    # Sub-chore preloads — same shape as the chore_id versions, but
    # keyed by sub_chore_id. Cooldown user scope follows the PARENT's
    # sharing mode (sub-chores credit the parent), so we look up the
    # parent's scope, not the sub-chore's own column.
    preload_sub_chore_lookups!
  end

  def preload_sub_chore_lookups!
    if @sub_chore_ids.empty?
      @last_completion_by_sub_chore = {}
      @last_completion_before_today_by_sub_chore = {}
      @completion_actor_by_sub_chore = {}
      @completions_today_by_sub_chore = {}
      return
    end

    sub_personal, sub_household = @sub_chore_ids.partition { |id|
      parent = @chores_by_id[id]&.parent_chore
      parent && parent.share_personal?
    }

    @last_completion_by_sub_chore =
      bulk_last_completion_for_sub(sub_personal, [viewer.id])
        .merge(bulk_last_completion_for_sub(sub_household, household_user_ids))

    @last_completion_before_today_by_sub_chore =
      bulk_last_completion_before_day_for_sub(sub_personal, [viewer.id])
        .merge(bulk_last_completion_before_day_for_sub(sub_household, household_user_ids))

    @completion_actor_by_sub_chore = bulk_last_actor_for_sub(sub_household, household_user_ids)

    personal_today = ChoreCompletion
      .where(day_key: day, sub_chore_id: sub_personal, user_id: viewer.id)
      .group(:sub_chore_id).count
    household_today = ChoreCompletion
      .where(day_key: day, sub_chore_id: sub_household, user_id: household_user_ids)
      .group(:sub_chore_id).count
    @completions_today_by_sub_chore = personal_today.merge(household_today)
  end

  def bulk_last_completion(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    ChoreCompletion
      .where(user_id: user_ids, chore_id: chore_ids)
      .select("DISTINCT ON (chore_id) chore_id, user_id, completed_at, payout_skipped, day_key, anonymous")
      .order(:chore_id, completed_at: :desc)
      .index_by(&:chore_id)
  end

  def bulk_last_completion_before_day(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    ChoreCompletion
      .where(user_id: user_ids, chore_id: chore_ids)
      .where(day_key: ...day)
      .select("DISTINCT ON (chore_id) chore_id, user_id, completed_at, payout_skipped, day_key, anonymous")
      .order(:chore_id, completed_at: :desc)
      .index_by(&:chore_id)
  end

  def bulk_last_actor(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    # Anonymous completions intentionally have no actor — exclude them
    # so the ring color / "completed by" label only reflects the most
    # recent *credited* completion.
    rows = ChoreCompletion.credited
      .where(user_id: user_ids, chore_id: chore_ids)
      .select("DISTINCT ON (chore_id) chore_id, user_id")
      .order(:chore_id, completed_at: :desc)
    actor_user_ids = rows.map(&:user_id).uniq
    actors = User.where(id: actor_user_ids).index_by(&:id)
    rows.each_with_object({}) { |r, h| h[r.chore_id] = actors[r.user_id] }
  end

  def bulk_last_completion_for_sub(sub_ids, user_ids)
    return {} if sub_ids.empty? || user_ids.empty?

    ChoreCompletion
      .where(user_id: user_ids, sub_chore_id: sub_ids)
      .select("DISTINCT ON (sub_chore_id) sub_chore_id, chore_id, user_id, completed_at, payout_skipped, day_key, anonymous")
      .order(:sub_chore_id, completed_at: :desc)
      .index_by(&:sub_chore_id)
  end

  def bulk_last_completion_before_day_for_sub(sub_ids, user_ids)
    return {} if sub_ids.empty? || user_ids.empty?

    ChoreCompletion
      .where(user_id: user_ids, sub_chore_id: sub_ids)
      .where(day_key: ...day)
      .select("DISTINCT ON (sub_chore_id) sub_chore_id, chore_id, user_id, completed_at, payout_skipped, day_key, anonymous")
      .order(:sub_chore_id, completed_at: :desc)
      .index_by(&:sub_chore_id)
  end

  def bulk_last_actor_for_sub(sub_ids, user_ids)
    return {} if sub_ids.empty? || user_ids.empty?

    rows = ChoreCompletion.credited
      .where(user_id: user_ids, sub_chore_id: sub_ids)
      .select("DISTINCT ON (sub_chore_id) sub_chore_id, user_id")
      .order(:sub_chore_id, completed_at: :desc)
    actor_user_ids = rows.map(&:user_id).uniq
    actors = User.where(id: actor_user_ids).index_by(&:id)
    rows.each_with_object({}) { |r, h| h[r.sub_chore_id] = actors[r.user_id] }
  end

  def bulk_completion_days(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    ChoreCompletion
      .where(user_id: user_ids, chore_id: chore_ids, day_key: (day - 14)..day)
      .distinct.pluck(:chore_id, :day_key)
      .group_by(&:first)
      .transform_values { |entries| entries.to_set(&:last) }
  end

  # Build the {B.id => A's max credited day_key} hash.
  #
  # The personal-vs-household split mirrors the rest of preload!: a
  # household-shared B looks at every household member's A
  # completions; a personal B only looks at the viewer's. We can't do
  # one global query because A's user-scope filter depends on B's
  # sharing mode.
  def bulk_anchor_last_days
    followers = @chores_by_id.values.select { |c| c.after_chore? && c.anchor_chore_id.present? }
    return {} if followers.empty?

    by_user_scope = followers.group_by { |c| c.share_household? ? :household : :personal }
    out = {}

    [:household, :personal].each { |scope|
      group = by_user_scope[scope] || []
      next if group.empty?

      anchor_ids = group.map(&:anchor_chore_id).uniq
      user_ids = scope == :household ? household_user_ids : [viewer.id]
      last_days = ChoreCompletion.credited
        .where(chore_id: anchor_ids, user_id: user_ids)
        .group(:chore_id).maximum(:day_key)

      group.each { |c| out[c.id] = last_days[c.anchor_chore_id] }
    }

    out
  end
end
