Buddy::Tools.register(
  name:        :search_inventory,
  description: <<~TXT,
    Find a PHYSICAL thing, or find out what's in a box. The inventory is the
    labelled boxes and bins around the house and everything filed inside them,
    several levels deep - "Basement > Tool Cubes > Batteries > AA".

    Use it for "where's the tent", "which bin are the christmas lights in",
    "do we still have any AA batteries", "what's in the camping tote", "what
    did I put in the attic". None of it is in your context - not one box, not
    the top-level names - so this is the ONLY way you know any of it. Guessing
    a location out loud is worse than useless here: they will go and look.

    `query` is what to find, in their words ("tent", "christmas lights",
    "drill bits"). It matches the name, the quick notes and the description,
    and NOT the path, so it finds the THING rather than everything that
    happens to sit under a box with that word in its name.

    `inside` is WHERE to look, and it takes the name of a box ("the garage",
    "camping tote"). With a `query` it narrows the search to that box and
    everything under it. On its OWN it means "what's in here" and lists what
    that box directly contains.

    Every row comes back with a `#HANDLE` off its label, where it lives, how
    many things it holds if it's a container, and whether it has photos. The
    handle is what the other inventory tools take, so answer or act in this
    same turn rather than saying you'll go and look. If a photo would answer
    it better than words, `show_inventory_image` puts it in front of them.

    Coming back empty is a real answer and they need it - "there's nothing in
    the inventory called that" sends them to look somewhere else, where a
    guess sends them to the wrong shelf. This is about physical things in
    boxes: a shopping list is `lists`, and a thing to do is not here at all.
  TXT
  feature:     :inventory,
  args:        {
    query:  { type: :string, required: false, description: "What to find, in their words" },
    inside: { type: :string, required: false, description: "Name of a box to look in, or to list the contents of" },
  },
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, _ctx) { { summary: "Look in the inventory", resolved: {} } },
  label:       ->(_payload, _ctx) { "Search inventory" },
  execute:     ->(payload, ctx) {
    found  = Buddy::Inventory.search(user: ctx.user, query: payload[:query], inside: payload[:inside])
    rows   = Buddy::Inventory.rows(found[:items])
    listed = found[:container] && payload[:query].blank?

    {
      searched: payload[:query].presence,
      inside:   found[:container]&.name,
      items:    rows,
      total:    found[:total],
      how:      (
        if rows.any? && listed
          "What's directly inside #{found[:container].name}#{" - #{rows.length} of #{found[:total]}" if found[:total] > rows.length}. " \
            "Anything marked as holding things is a box with more inside it, which you can open " \
            "with `inside` again. Tell them in your own words; don't read the list back."
        elsif rows.any?
          "Nearest match first#{" - #{rows.length} of #{found[:total]} shown" if found[:total] > rows.length}. " \
            "Answer from THIS. Say WHERE the thing is - the path is the whole point of the answer - " \
            "and give it the way they'd walk to it. To change one, pass its `#HANDLE` to " \
            "`edit_inventory_item`."
        elsif found[:container]
          "NOTHING in #{found[:container].name} matching that. Say so plainly - it isn't in there, " \
            "and that is worth knowing. Offer to look somewhere else, or across the whole inventory."
        else
          "NOTHING in the inventory matching that. Say so plainly rather than naming a box that " \
            "sounds close - they will go and open it. It may simply never have been filed; offer " \
            "to add it if they tell you where it lives."
        end
      ),
    }.compact
  },
)
