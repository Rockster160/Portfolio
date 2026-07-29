module Buddy
  # Historical daily-chore progress, looked up ON DEMAND (via the chore_progress
  # tool) rather than preloaded into every turn's context. Answers "did I get
  # everything done yesterday" / "how'd my dailies go this week" by checking, per
  # day, how many of the person's daily-rotation chores were completed.
  #
  # Uses the CURRENT daily list as the checklist for each past day (the rotation
  # can drift, but this is the useful approximation). Shared chores count if
  # anyone in the household did them; personal chores only if THIS person did.
  module ChoreHistory
    module_function

    # Returns one row per day (oldest → newest):
    #   { date:, done:, total:, missed: [names] }
    def progress(user, days: 7)
      return [] unless user.respond_to?(:chore_household_id) && user.chore_household_id

      dailies = ChoreDaily.for_user(user).includes(:chore).filter_map(&:chore)
      return [] if dailies.empty?

      days   = days.to_i.clamp(1, 31)
      today  = user.perceived_today
      range  = (today - (days - 1))..today
      hh_ids = user.chore_household&.member_user_ids || [user.id]

      credited = credited_by_day(hh_ids, range, user.id)

      range.map { |day|
        sets   = credited[day] || { anyone: Set.new, me: Set.new }
        missed = dailies.reject { |c| done?(c, sets) }
        { date: day, done: dailies.size - missed.size, total: dailies.size, missed: missed.map(&:name) }
      }
    end

    class << self
      private

      # Per day → the set of chore_ids credited (by anyone / by this user).
      # A completion credits BOTH the tapped chore and its parent, so a sub-chore
      # tap still marks the parent daily done.
      def credited_by_day(household_ids, range, me_id)
        out = Hash.new { |h, k| h[k] = { anyone: Set.new, me: Set.new } }
        ChoreCompletion
          .where(user_id: household_ids, day_key: range, anonymous: false)
          .pluck(:day_key, :chore_id, :parent_chore_id, :user_id)
          .each { |day, cid, pid, uid|
            [cid, pid].compact.each { |id|
              out[day][:anyone] << id
              out[day][:me] << id if uid == me_id
            }
          }
        out
      end

      def done?(chore, sets)
        shared = chore.respond_to?(:share_household?) && chore.share_household?
        (shared ? sets[:anyone] : sets[:me]).include?(chore.id)
      end
    end
  end
end
