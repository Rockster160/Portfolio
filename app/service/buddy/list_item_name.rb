module Buddy
  # Tidies an item name on its way onto a list. Buddy passes the person's own
  # words through, which is right for the substance ("sanitizer for hike") and
  # wrong for the grammar around it: a list reads "Chicken salad for mom", never
  # "a chicken salad for mom".
  module ListItemName
    module_function

    ARTICLE_RX = /\A(?:a|an|the|some)\s+/i
    # A capitalized article in front of another capital is part of a name -
    # "The Office" on a watch list, "A Christmas Carol" - not grammar to trim.
    TITLE_RX = /\A(?:A|An|The|Some)\s+[[:upper:]]/
    STYLE_SAMPLE = 20

    def tidy(raw, list: nil)
      name = raw.to_s.squish
      return name if name.match?(TITLE_RX)

      trimmed = name.sub(ARTICLE_RX, "")
      return name if trimmed == name || trimmed.blank?

      capitalized?(list) ? trimmed.sub(/\A./, &:upcase) : trimmed
    end

    # Follow the list's own house style rather than forcing a capital: a list
    # whose items are all lowercase shouldn't sprout one capitalized entry just
    # because the article in front of it got cut. An empty list has no style
    # yet, so it gets the ordinary one.
    def capitalized?(list)
      return true if list.nil?

      names = list.list_items.limit(STYLE_SAMPLE).pluck(:name).map { |n| n.to_s.strip }.compact_blank
      return true if names.empty?

      names.count { |n| n.match?(/\A[[:upper:]]/) } * 2 >= names.size
    end
  end
end
