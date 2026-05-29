# Bulk-loaded shared state for ChoreSerializer. Built ONCE per request
# (or once per `/sync` call), then passed into each individual
# ChoreSerializer so the per-chore JSON build is O(1) DB-wise.
#
# `for_user` is the high-level entry point — give it the viewer, get
# back a context preloaded for all of that user's accessible chores.
class ChoreSerializerContext
  attr_reader :viewer, :day, :hot_picks,
              :completions_today, :last_completion_by_chore,
              :completion_actor_by_chore, :completion_days_by_chore,
              :household_user_ids

  def self.for_user(viewer, day: nil)
    new(viewer: viewer, day: day || ChoreDay.current(viewer))
  end

  def initialize(viewer:, day:)
    @viewer = viewer
    @day = day
    @household_user_ids = Chore.household_user_ids_for(viewer.id)
    chores = viewer.accessible_chores.to_a
    @chore_ids = chores.map(&:id)
    @household_chore_ids = chores.select(&:share_household?).map(&:id)
    @personal_chore_ids  = @chore_ids - @household_chore_ids
    preload!
  end

  def serialize_all(chores)
    chores.map { |c| ChoreSerializer.new(c, viewer: viewer, ctx: self).as_json }
  end

  private

  def preload!
    @hot_picks = ChoreHotPick.lookup_for(day)

    @last_completion_by_chore = bulk_last_completion(@personal_chore_ids, [viewer.id])
      .merge(bulk_last_completion(@household_chore_ids, household_user_ids))

    @completion_actor_by_chore = bulk_last_actor(@household_chore_ids, household_user_ids)

    @completions_today = ChoreCompletion
      .where(day_key: day, chore_id: @personal_chore_ids, user_id: viewer.id)
      .group(:chore_id).count
      .merge(
        ChoreCompletion
          .where(day_key: day, chore_id: @household_chore_ids, user_id: household_user_ids)
          .group(:chore_id).count
      )

    @completion_days_by_chore = ChoreCompletion
      .where(user_id: viewer.id, chore_id: @chore_ids, day_key: (day - 14)..day)
      .distinct.pluck(:chore_id, :day_key)
      .group_by(&:first)
      .transform_values { |entries| entries.map(&:last).to_set }
  end

  def bulk_last_completion(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    ChoreCompletion
      .where(user_id: user_ids, chore_id: chore_ids)
      .select("DISTINCT ON (chore_id) chore_id, user_id, completed_at, payout_skipped, day_key")
      .order(:chore_id, completed_at: :desc)
      .index_by(&:chore_id)
  end

  def bulk_last_actor(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    rows = ChoreCompletion
      .where(user_id: user_ids, chore_id: chore_ids)
      .select("DISTINCT ON (chore_id) chore_id, user_id")
      .order(:chore_id, completed_at: :desc)
    actor_user_ids = rows.map(&:user_id).uniq
    actors = User.where(id: actor_user_ids).index_by(&:id)
    rows.each_with_object({}) { |r, h| h[r.chore_id] = actors[r.user_id] }
  end
end
