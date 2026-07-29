module Buddy
  # Rough pebble-reward guess for a Buddy-created chore when the person didn't
  # name an amount. There's no formal reward table in the app — the chore form
  # just offers 1 / 2 / 3 / 5 / 10 / 15 as quick picks — so this mirrors that
  # scale by effort so a new chore is never silently worth 0. Always
  # overridable with an explicit amount.
  module PebbleGuide
    module_function

    # Bigger, sweatier jobs.
    BIG = /\b(deep ?clean|mow|lawn|laundry|vacuum|mop|scrub|bathroom|garage|yard|wash the car|meal ?prep|grocer|declutter|organize|clean out)\b/i
    # Quick daily-habit taps.
    SMALL = /\b(water|vitamin|pill|meds?|muti|brush|floss|wordle|read(ing)?|stretch|make (the )?bed|feed|puppy|kitty|cat)\b/i

    def guess(name)
      n = name.to_s
      return 10 if n.match?(BIG)
      return 1  if n.match?(SMALL)

      3 # sensible middle for an ordinary chore
    end
  end
end
