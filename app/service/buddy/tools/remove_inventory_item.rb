Buddy::Tools.register(
  name:        :remove_inventory_item,
  description: <<~TXT,
    Take something out of the inventory - it's been used up, thrown out, given
    away, or it was never really in there. "We finished the AA batteries",
    "the camp stove is gone", "drop that bin, it's empty now".

    Only when the thing is no longer THERE. Something that has merely moved is
    `edit_inventory_item` with `into`, and that is what nearly every "it's not
    in the basement any more" turns out to be - ask where it went rather than
    removing it, because a thing removed and then re-added loses its notes,
    its photos and the handle on its label.

    `item` takes a `#HANDLE` off a `search_inventory` row, or its name. Prefer
    the handle: this is the one tool here where matching the wrong row costs
    something that can't simply be moved back.

    REMOVING A BOX REMOVES WHAT'S IN IT. If they name a container, everything
    filed inside goes with it, and the card says how many. That is usually
    what "get rid of that bin" means, but it is worth being sure it isn't
    "empty the bin out" - which is moving the contents somewhere else first.
    Photos of a box go with it and do not come back.
  TXT
  feature:     :inventory,
  args:        {
    item: { type: :string, required: true, description: "The thing to remove - a #HANDLE, or its name" },
  },
  confirm:     ->(payload, ctx) {
    box    = Buddy::Inventory.resolve!(ctx.user, payload[:item], verb: "remove")
    inside = box.descendants
    if inside.length + 1 > Buddy::Inventory::REMOVE_CAP
      raise "#{box.name} has #{inside.length} things filed under it - too much to take out from here, " \
            "and there'd be no putting it back. That one wants doing in the Inventory app"
    end

    held = ("and the #{inside.length} #{"thing".pluralize(inside.length)} inside it" if inside.any?)
    {
      summary:  ["Remove #{box.name}", held].compact.join(" ") + " from the inventory?",
      resolved: { box_key: box.param_key, was_named: box.name, held: inside.length, where: Buddy::Inventory.location_of(box) },
    }
  },
  label:       ->(payload, _ctx) {
    sub = ["🗑️ from #{payload[:where]}"]
    sub << "takes #{payload[:held]} #{"thing".pluralize(payload[:held].to_i)} with it" if payload[:held].to_i.positive?
    { title: payload[:was_named].presence || payload[:item].to_s, sub: sub.join("\n") }
  },
  # Level 2, like removing from a list: it goes immediately and unticks back
  # on. The undo below is what earns that - without it this would be a delete
  # with a friendly name.
  level:       2,
  execute:     ->(payload, ctx) {
    box = Buddy::Inventory.find!(ctx.user, payload[:box_key])
    # Snapshot the whole branch BEFORE destroying it. Contents are
    # `dependent: :destroy`, so a moment later there is nothing left to read
    # these off - and parents lead the list because a child recreated first has
    # no box to be inside.
    doomed = [box, *box.descendants]
    reverts = doomed.map { |row|
      { op: "recreated", model: "Box", attrs: row.attributes.except("id", "created_at", "updated_at"), summary: "put #{box.name} back" }
    }
    # The photos come back too, as long as their blobs outlive the delete -
    # ActiveStorage purges in a background job, and the undo window is minutes.
    doomed.each { |row|
      row.images.each { |image|
        reverts << {
          op:      "recreated",
          model:   "BoxImage",
          blob_id: image.file&.blob&.id,
          attrs:   image.attributes.except("id", "created_at", "updated_at"),
          summary: "put #{box.name} back",
        }
      }
    }
    box.destroy!

    { item: payload[:was_named], held: payload[:held].to_i, where: payload[:where], reverts: reverts }
  },
  receipt:     ->(result, _ctx) {
    took = (" (and the #{result[:held]} #{"thing".pluralize(result[:held])} in it)" if result[:held].to_i.positive?)
    "Took **#{result[:item]}**#{took} out of #{result[:where]} ✓"
  },
)
