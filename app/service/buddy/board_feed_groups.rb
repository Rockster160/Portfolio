module Buddy
  # Groups something has been SENT to - a board sound, a duration ring, an
  # alert, a timer - kept per owner. No chore, routine or button carries such a
  # group, so without this a board could never be pointed at one. A group shows
  # up here because a broadcast was aimed at it, never because code names it.
  module BoardFeedGroups
    module_function

    CACHE = :board_feed_groups

    def remember!(user, groups)
      return if user.nil?

      tags = GroupTaggable.normalize(groups)
      known = names(user)
      added = tags.reject { |tag| known.any? { |k| k.casecmp?(tag) } }
      return if added.empty?

      user.caches.set(CACHE, { groups: known + added })
    end

    def names(user)
      Array(user.caches.get(CACHE).to_h.with_indifferent_access[:groups])
    end
  end
end
