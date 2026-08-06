module Buddy
  # Finding a pairing from either end.
  #
  # A person naming a link names whichever half they were thinking about — the
  # chore, or the thing that follows it — and has no idea which side of the row
  # it landed on. Searching one side only means "unlink the coffee thing" works
  # about half the time, which is worse than not working at all.
  module LinkFinder
    module_function

    def matching(user, name, other=nil)
      needle = name.to_s.downcase.strip
      return [] if needle.empty?

      rows = RecordLink.where(user_id: user.id).select { |l|
        [l.source_name, l.target_name].any? { |n| n.to_s.downcase == needle }
      }
      return rows if other.to_s.strip.empty?

      far = other.to_s.downcase.strip
      rows.select { |l| [l.source_name, l.target_name].any? { |n| n.to_s.downcase == far } }
    end
  end
end
