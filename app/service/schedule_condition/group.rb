module ScheduleCondition
  # The `all` and `any` kinds: several conditions as one rule.
  module Group
    module_function

    # A part that can't be answered only matters when the parts that CAN be
    # don't already settle it. "After ten and the garage is open" at 3pm is a
    # no, whatever the garage sensor is doing - so a definite answer from one
    # part wins, and the unanswerable one only raises when it would have been
    # the deciding vote. Raising then hands it to the caller's own policy, the
    # same as a lone condition that can't be answered.
    def answer(data)
      settles = data[:kind] != :all
      unknown = nil
      data[:of].each { |part|
        begin
          return settles if yield(part) == settles
        rescue StandardError => e
          unknown ||= e
        end
      }
      raise unknown if unknown

      !settles
    end

    # Every one required unless `match` says any.
    #
    # Takes what the model sends - a JSON array of plain objects, or the array
    # itself - and folds in the single check a tool may also have been given
    # through its older arguments, so the two ways of saying it combine instead
    # of one quietly winning.
    def from_rows(rows, match: :all, also: nil)
      list = rows.is_a?(Array) ? rows : parse_rows(rows)
      kind = (match.to_s == "any" ? :any : :all)
      parts = list.map { |row| row.respond_to?(:to_h) ? row.to_h : {} }
      combined = parts.empty? ? nil : ScheduleCondition.normalize({ kind: kind, of: parts })
      return ScheduleCondition.normalize(also) if combined.nil?
      return combined if also.blank?

      ScheduleCondition.normalize({ kind: :all, of: [also, combined] })
    end

    def parse_rows(value)
      return [] if value.blank?

      rows = JSON.parse(value.to_s) rescue nil
      rows = [rows] if rows.is_a?(Hash)
      raise "conditions need to be a JSON array of objects" unless rows.is_a?(Array)

      rows
    end
  end
end
