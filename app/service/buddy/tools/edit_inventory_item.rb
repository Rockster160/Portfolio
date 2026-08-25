Buddy::Tools.register(
  name:        :edit_inventory_item,
  description: <<~TXT,
    Change something in the inventory: rename it, put a note on it, or MOVE it
    into a different box. Only pass the fields that are changing.

    MOVING IS THE COMMON ONE, and `into` is how it's done - the name of the box
    it's going into. "The tent's in the garage now, not the basement", "put the
    drill in the tool cubes", "shift the whole camping tote up to the attic".
    A box moves exactly like an item does, and everything inside it goes along
    with it: the tote lands in the attic with all its contents still in it.
    Pass `into: "top"` for something that no longer sits inside anything.

    `item` names what's being changed and takes a `#HANDLE` off a
    `search_inventory` row when you have one. Prefer the handle - names repeat
    in an inventory, and when two boxes are called the same thing you'll be
    told to ask which rather than being handed a guess.

    `rename` fixes the name. `notes` is the short line under it, `description`
    anything longer; both replace what was there rather than adding to it, so
    if they're adding to a note you already know, write out the whole thing.

    To take something out of the inventory entirely, that's
    `remove_inventory_item`. This is for a thing that still exists and has
    changed - moved, renamed, or newly described.
  TXT
  feature:     :inventory,
  args:        {
    item:        { type: :string, required: true,  description: "The thing to change - a #HANDLE, or its name" },
    rename:      { type: :string, required: false, description: "New name" },
    into:        { type: :string, required: false, description: "Box to move it into, or \"top\" for the top level" },
    notes:       { type: :string, required: false, description: "Short line shown under the name - replaces what's there" },
    description: { type: :string, required: false, description: "Anything longer - replaces what's there" },
  },
  confirm:     ->(payload, ctx) {
    box      = Buddy::Inventory.resolve!(ctx.user, payload[:item], verb: "change")
    resolved = { box_key: box.param_key, was_named: box.name }

    if payload[:into].present?
      if Buddy::Inventory::TOP_LEVEL_WORDS.include?(payload[:into].to_s.strip.downcase)
        resolved[:parent_key] = nil
        resolved[:moving_to]  = "the top level"
      else
        parent = Buddy::Inventory.resolve!(ctx.user, payload[:into], verb: "move it into", arg: :into)
        raise "#{box.name} can't go inside itself" if parent.param_key == box.param_key
        # `hierarchy_ids` is every ancestor of the target. If the thing being
        # moved is one of them, this is a box being filed into its own contents
        # - the tree would close into a loop and the whole branch would drop off
        # the top of the inventory, which is not a thing anyone would notice
        # until they went looking for it.
        raise "#{parent.name} is inside #{box.name} - that would fold the box into itself" if Array(parent.hierarchy_ids).include?(box.param_key)

        resolved[:parent_key] = parent.param_key
        resolved[:moving_to]  = Buddy::Inventory.path_of(parent)
      end
      resolved[:moving_from] = Buddy::Inventory.location_of(box)
    end

    changes = []
    changes << "rename to #{payload[:rename]}" if payload[:rename].present?
    changes << "move to #{resolved[:moving_to]}" if resolved.key?(:moving_to)
    changes << "re-note" if payload[:notes].present? || payload[:description].present?
    raise "nothing to change about #{box.name}" if changes.empty?

    { summary: "#{box.name}: #{changes.join(", ")}?", resolved: resolved }
  },
  label:       ->(payload, _ctx) {
    diffs = []
    diffs << "→ #{payload[:rename]}" if payload[:rename].present?
    diffs << "📦 #{payload[:moving_from]} → #{payload[:moving_to]}" if payload[:moving_to].present?
    diffs << "📝 #{payload[:notes]}" if payload[:notes].present?
    { title: payload[:was_named].presence || payload[:item].to_s, sub: diffs.join("\n").presence }
  },
  # Level 2, like every other edit: it lands as a pre-checked row and `before`
  # below holds exactly what was overwritten, so unticking puts it back.
  level:       2,
  execute:     ->(payload, ctx) {
    box   = Buddy::Inventory.find!(ctx.user, payload[:box_key])
    attrs = {}
    attrs[:name]        = payload[:rename]      if payload[:rename].present?
    attrs[:notes]       = payload[:notes]       if payload[:notes].present?
    attrs[:description] = payload[:description] if payload[:description].present?
    # Written even when nil: `into: "top"` is a real move OUT of a box, and
    # `.present?` would read it as nothing having been asked for.
    attrs[:parent_key]  = payload[:parent_key]  if payload.key?(:moving_to)

    before = attrs.keys.index_with { |key| box.public_send(key) }
    prior  = box.name
    box.update!(attrs) unless attrs.empty?

    {
      box_key:        box.param_key,
      item:           box.name,
      moved_to:       payload[:moving_to],
      updated_fields: attrs.keys,
      revert:         { op: "updated", model: "Box", id: box.param_key, before: before, summary: "put #{prior} back" },
    }
  },
  receipt:     ->(result, _ctx) {
    next "**#{result[:item]}** is in #{result[:moved_to]} now ✓" if result[:moved_to].present?

    "Updated **#{result[:item]}** ✓"
  },
)
