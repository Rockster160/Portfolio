# Free-text GROUP tags on a record — the way a chore board gathers what it shows.
# A record can carry several; a board can watch several; any shared tag is a match.
# Stored in a `tags` text[] column, matched case-insensitively ("Home" and "home"
# are one group to everyone but the database), and normalized on write: trimmed,
# blanks dropped, de-duped case-insensitively keeping the first spelling so the
# picker reads the way it was typed.
#
# This is the board's own tagging, deliberately NOT the Tag/Taggable join used by
# pages and contacts: those are global, lower-cased rows; a group here is just a
# word a household files things under, and one nobody uses disappears by nobody
# using it rather than by being deleted somewhere.
module GroupTaggable
  extend ActiveSupport::Concern

  included do
    before_validation :normalize_group_tags

    # Records sharing ANY of the wanted tags, compared case-insensitively.
    scope :tagged, ->(wanted) {
      list = GroupTaggable.normalize(wanted).map(&:downcase)
      next none if list.empty?

      where(
        "EXISTS (SELECT 1 FROM unnest(#{table_name}.tags) t WHERE LOWER(t) = ANY (ARRAY[?]))",
        list,
      )
    }

    # Every distinct tag in scope, for the form's datalist and the board picker,
    # de-duped case-insensitively and sorted by how it reads.
    scope :tag_names, -> {
      pluck(:tags).flatten.compact_blank.uniq(&:downcase).sort_by(&:downcase)
    }
  end

  # CSV strings or arrays in, a clean display-cased list out.
  def self.normalize(value)
    Array(value)
      .flat_map { |entry| entry.to_s.split(",") }
      .map(&:strip)
      .compact_blank
      .uniq(&:downcase)
  end

  private

  def normalize_group_tags
    self.tags = GroupTaggable.normalize(tags)
  end
end
