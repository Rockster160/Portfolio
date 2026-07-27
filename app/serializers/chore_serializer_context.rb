# Bulk-loaded shared state for ChoreSerializer. Built ONCE per request
# (or once per `/sync` call), then passed into each individual
# ChoreSerializer so the per-chore JSON build is O(1) DB-wise.
#
# `for_user` is the high-level entry point — give it the viewer, get
# back a context preloaded for all of that user's accessible chores.
#
# Family-aware lookups: every by-chore hash answers "what's the state of
# THIS chore" where "this chore" means either its own row (for leaves +
# sub-chores) OR its own row PLUS every sub-chore tap under it (for
# parents). Concretely, the SQL condition `chore_id = X OR parent_chore_id
# = X` unifies both cases — a leaf/sub matches only via `chore_id`, a
# parent matches via `chore_id` AND `parent_chore_id`. In Ruby we index
# each completion into every accessible chore.id it belongs to.
class ChoreSerializerContext
  attr_reader :viewer, :day, :hot_picks,
    :completions_today, :last_completion_by_chore,
    :last_completion_before_today_by_chore,
    :completion_actor_by_chore, :completion_days_by_chore,
    :completion_days_before_today_by_chore,
    :anchor_last_day_by_chore,
    :household_user_ids, :daily_chore_ids,
    :household_icons_by_id

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
    # Effective sharing mode follows the parent for sub-chores — the
    # sub-chore's completions live under the parent's user scope
    # (household-shared parents pull in every household member's taps).
    @household_chore_ids, @personal_chore_ids = chores.partition { |c|
      (c.parent_chore || c).share_household?
    }.map { |set| set.map(&:id) }
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
    @completions_today = bulk_completions_today(@personal_chore_ids, [viewer.id])
      .merge(bulk_completions_today(@household_chore_ids, household_user_ids))

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
  end

  # Every row is fanned into up to two hash entries: one keyed by
  # `chore_id` (the leaf / sub-chore's own answer) and one keyed by
  # `parent_chore_id` when set (the parent's aggregated answer). We
  # only index keys that live in `chore_ids` — completions under a
  # different pool (personal vs household) are ignored.
  def bulk_last_completion(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    rows = ChoreCompletion
      .where(user_id: user_ids)
      .where("chore_id IN (:ids) OR parent_chore_id IN (:ids)", ids: chore_ids)
      .select(:id, :chore_id, :parent_chore_id, :user_id, :completed_at, :payout_skipped, :day_key, :anonymous)
      .order(completed_at: :desc)
    fan_out_first(rows, chore_ids)
  end

  def bulk_last_completion_before_day(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    rows = ChoreCompletion
      .where(user_id: user_ids, day_key: ...day)
      .where("chore_id IN (:ids) OR parent_chore_id IN (:ids)", ids: chore_ids)
      .select(:id, :chore_id, :parent_chore_id, :user_id, :completed_at, :payout_skipped, :day_key, :anonymous)
      .order(completed_at: :desc)
    fan_out_first(rows, chore_ids)
  end

  def bulk_last_actor(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    # Anonymous completions intentionally have no actor — exclude them
    # so the ring color / "completed by" label only reflects the most
    # recent *credited* completion.
    rows = ChoreCompletion.credited
      .where(user_id: user_ids)
      .where("chore_id IN (:ids) OR parent_chore_id IN (:ids)", ids: chore_ids)
      .select(:id, :chore_id, :parent_chore_id, :user_id, :completed_at)
      .order(completed_at: :desc)
    picks = fan_out_first(rows, chore_ids)
    actor_ids = picks.values.map(&:user_id).uniq
    actors = User.where(id: actor_ids).index_by(&:id)
    picks.transform_values { |c| actors[c.user_id] }
  end

  def bulk_completions_today(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    target = chore_ids.to_set
    counts = Hash.new(0)
    ChoreCompletion
      .where(day_key: day, user_id: user_ids)
      .where("chore_id IN (:ids) OR parent_chore_id IN (:ids)", ids: chore_ids)
      .pluck(:chore_id, :parent_chore_id).each do |cid, pid|
        counts[cid] += 1 if target.include?(cid)
        counts[pid] += 1 if pid && target.include?(pid)
      end
    counts
  end

  def bulk_completion_days(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    target = chore_ids.to_set
    out = Hash.new { |h, k| h[k] = Set.new }
    ChoreCompletion
      .where(user_id: user_ids, day_key: (day - 14)..day)
      .where("chore_id IN (:ids) OR parent_chore_id IN (:ids)", ids: chore_ids)
      .pluck(:chore_id, :parent_chore_id, :day_key).each do |cid, pid, dk|
        out[cid] << dk if target.include?(cid)
        out[pid] << dk if pid && target.include?(pid)
      end
    out
  end

  # Walk `rows` (already ordered by completed_at DESC) and take the
  # first row that lands on each accessible chore id. Each row can hit
  # up to two entries: its own chore_id and its parent_chore_id.
  def fan_out_first(rows, chore_ids)
    target = chore_ids.to_set
    out = {}
    rows.each do |r|
      out[r.chore_id] ||= r if target.include?(r.chore_id)
      out[r.parent_chore_id] ||= r if r.parent_chore_id && target.include?(r.parent_chore_id)
    end
    out
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
      # Anchor completions can be sub-chore taps too — a parent-anchored
      # follower fires when ANY sub-chore of the parent is credited.
      # Same family-aware OR as the other lookups.
      last_days = ChoreCompletion.credited
        .where(user_id: user_ids)
        .where("chore_id IN (:ids) OR parent_chore_id IN (:ids)", ids: anchor_ids)
        .pluck(:chore_id, :parent_chore_id, :day_key)
        .each_with_object({}) { |(cid, pid, dk), h|
          [cid, pid].each { |k|
            next if k.nil? || !anchor_ids.include?(k)

            h[k] = dk if h[k].nil? || dk > h[k]
          }
        }

      group.each { |c| out[c.id] = last_days[c.anchor_chore_id] }
    }

    out
  end
end
