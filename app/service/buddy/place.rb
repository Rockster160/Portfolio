# The basic form of a place — what a person says out loud when they mention
# where something is.
#
# A calendar `location` is whatever got typed or synced into it, and that is
# often a full postal address: street number, city, state, ZIP, country. Read
# back in a sentence it becomes "Monday's plunge with Wil is still on the board
# for Horsetail Falls, Alpine, UT" — a briefing reciting a mailing label for a
# canyon Rocco has driven to a hundred times. He asked for the short form
# everywhere except when he asks for the address on purpose: "a hair
# appointment in Sandy" over the street number and the ZIP.
#
# So this decides it in Ruby rather than asking the model to be brief. Two
# shapes cover nearly everything real:
#
#   "Horsetail Falls, Alpine, UT"        -> Horsetail Falls   (a named place)
#   "12723 S Park Ave, Riverton, UT ..." -> Riverton          (a street address)
#
# A place that leads with a house number has no name to give, so the city is
# the useful half; anything else already leads with its name. Either answer is
# one he named himself as fine.
#
# Commas are not required for either. Plenty of them arrive as one run —
# "1061 E 1300 S Salt Lake City" — and the city is still the answer; see
# `city_in` for the two ways a street ends.
#
# What it deliberately does NOT do is guess. Where there is no city to find —
# "4512 Bartlett Dr." — it hands back what it was given rather than slicing at
# a plausible-looking word, because half an address is worse than a whole one.
# The full address stays reachable through `search_agenda`, which is what a
# deliberate question about an address goes through.
module Buddy
  module Place
    module_function

    # A meeting link is not an address, and every one of these is unique past
    # the domain — there is no short form, only a broken one.
    LINK_RX = %r{\A(?:https?://|www\.)}i

    # Trailing state / ZIP / country, in any run and with or without the
    # commas. Anchored at the end so `Utah State Fair Park` keeps its name and
    # only `... Taylorsville Utah 84129 United States` loses its tail.
    #
    # A state code is matched CASE-SENSITIVELY and on a word boundary, and both
    # halves are load-bearing: without them the two-letter alternative ate the
    # last two letters of whatever it landed on, and `1061 E 1300 S Salt Lake
    # City` came back as `1061 E 1300 S`.
    TAIL_RX = /(?:\s*,?\s*\b(?:united states|usa|u\.s\.a?\.|utah|\d{5}(?:-\d{4})?|(?-i:[A-Z]{2})))+\s*\z/i

    # What a person puts between a place and its city: a comma, a newline out
    # of a synced calendar, or the dash in "Walmart- Herriman". The dash needs
    # a following space or it eats `OCS-3-Large Conference Room`.
    SPLIT_RX = /\s*[,\n]\s*|\s+-\s+|(?<=\w)-\s+/

    # The word that ends a street. Whatever comes after one is the city.
    STREET_TYPE_RX = /\A(?:st|street|ave|avenue|rd|road|dr|drive|ln|lane|blvd|boulevard|way|ct|court|pl|place|cir|circle|pkwy|parkway|ter|terrace|hwy|highway)\.?\z/i

    DIRECTION_RX = /\A(?:[nsew]|ne|nw|se|sw|north|south|east|west)\.?\z/i

    HOUSE_NUMBER_RX = /\A\d+\z/

    # A suite sits between the street and the city and belongs to neither.
    UNIT_RX = /\A(?:suite|ste|unit|apt|apartment|bldg|building|fl|floor|rm|room|#\d*)\.?\z/i

    def short(location)
      raw = location.to_s.strip
      return nil if raw.blank?
      return raw if raw.match?(LINK_RX)

      parts = raw.sub(TAIL_RX, "").split(SPLIT_RX).map(&:strip).compact_blank
      return raw if parts.empty?

      # A street address gives up its name for its city; a named place is
      # already the answer, minus any street that got typed after it.
      pick = street?(parts.first) ? city_in(parts.last) : drop_street(parts.first)
      shout?(pick) ? pick.split.map(&:capitalize).join(" ") : pick
    end

    # Leads with a house number.
    def street?(part)
      part.match?(/\A\d/)
    end

    # `Mountain America Exposition Center 9575 S. State St. Sandy` is a name
    # with an address stuck on the end. Cut at the house number — three digits
    # or more, and never the last word, so `Studio 54` and `Conference Room
    # 100` keep theirs.
    def drop_street(part)
      words = part.split
      at    = words.each_index.find { |i| i.positive? && i < words.length - 1 && words[i].match?(/\A\d{3,}\z/) }
      at ? words.first(at).join(" ") : part
    end

    # The city at the end of an address that carries no comma to find it by.
    # Utah writes a street two ways and each ends somewhere different:
    #
    #   1971 E Forest Creek Ln Cottonwood Heights  -> a street TYPE ends it
    #   1061 E 1300 S Salt Lake City               -> a numbered street and its
    #                                                 direction end it
    #
    # The grid form needs the last number NOT to be the house number, or
    # "12723 S Park Ave" reads its own street as a city.
    def city_in(part)
      words = part.split

      ends = words.each_index.select { |i| words[i].match?(STREET_TYPE_RX) }.max
      city = drop_unit(words[(ends + 1)..]) if ends
      return city.join(" ") if city.present?

      last = words.each_index.select { |i| words[i].match?(HOUSE_NUMBER_RX) }.max
      grid = last&.positive? && words[last + 1]&.match?(DIRECTION_RX) && last + 2 <= words.length - 1
      return words[(last + 2)..].join(" ") if grid

      without_house_number(part)
    end

    # "11820 S State St Suite 320 Draper" — the suite is neither the street nor
    # the city, and left in it made the city read as "Suite 320 Draper".
    def drop_unit(words)
      return words unless words.first&.match?(UNIT_RX)

      rest = words.drop(1)
      rest.first&.match?(HOUSE_NUMBER_RX) ? rest.drop(1) : rest
    end

    # Nothing in here names a city: "4512 Bartlett Dr." is a street and a house
    # number and that is all. He does not want the number said either — "street
    # numbers and ... the zip and state and all of that excessive info that I
    # already know" — so it goes, and the street is what is left to say.
    def without_house_number(part)
      words = part.split
      return part unless words.first&.match?(HOUSE_NUMBER_RX)

      rest = words.drop(1)
      rest = rest.drop(1) if rest.first&.match?(DIRECTION_RX)
      rest.join(" ").presence || part
    end

    # A synced calendar shouts its cities. Said back as written it reads like
    # an abbreviation nobody expands.
    def shout?(part)
      part == part.upcase && part.match?(/[A-Z]{2,}/)
    end
  end
end
