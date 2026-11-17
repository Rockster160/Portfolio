Buddy::Tools.register(
  name:        :add_inventory_item,
  summary:     "File a physical thing into a labelled box or bin so it's findable later. Finding " \
               "one is search_inventory; moving one is edit_inventory_item.",
  description: <<~TXT,
    File a physical thing into the inventory - the labelled boxes and bins
    around the house. Use it when they've just put something away and want it
    findable: "the tent's in the camping tote now", "add the drill bits to the
    tool cubes", "I've started a box in the attic for baby clothes".

    THIS IS NOT A LIST. `add_list_item` is for something to buy or something
    to do; this is for an object that now physically lives somewhere. "Add
    batteries to the shopping list" is a list. "The spare batteries are in the
    tool cubes" is this.

    `item` is the thing, named the way they'd search for it later - "Camp
    Stove", not "the camp stove I got from Dave". A count goes in `notes`, not
    the name: "wire clips x4" is item "Wire Clips", notes "4".

    `inside` is the box it goes in. One name finds that box wherever it is
    ("camping tote", "tool cubes"). A path walks down from the first name,
    each step inside the one before, written with " > ": "Desk > Tool Drawer >
    Mini Kobalt Toolbox > Top Drawer". Use the path whenever they describe
    where it sits, so "the top drawer" is the one in the toolbox and not some
    other top drawer. Leave `inside` off only for something that sits on its
    own at the top level, like a room or a shelf.

    A box and an item are the same kind of row, so a drawer, a toolbox and a
    marker are all filed the same way. Set `make_boxes` when they're setting
    up a place as they describe it, or have said to create what isn't there:
    the boxes along the path that don't exist yet are made in it, in order.
    Set it on EVERY call that names a box that doesn't exist yet, including
    boxes an earlier call in the same reply is making - every call is checked
    before any of them runs. Without it, a path that leads nowhere comes back
    as an error naming the step that's missing, and then the question is
    whether to make it, not what the existing boxes are called.

    `notes` is the short line that shows under the name in the tree - a count,
    a size, a colour, which one it is. `description` is for anything longer.
    Both are searchable later, so what they said about the thing is worth
    keeping: "12 of them, the long ones" is how they'll find it again.

    One call per thing. Several things into the same box is several calls.
  TXT
  feature:     :inventory,
  args:        {
    item:        { type: :string, required: true,  description: "The thing, named the way they'd search for it" },
    inside:      { type: :string, required: false, description: "Name of the box it goes in - leave off for the top level" },
    notes:       { type: :string, required: false, description: "Short line shown under the name" },
    description: { type: :string, required: false, description: "Anything longer worth keeping" },
    make_boxes:  { type: :boolean, required: false, description: "Make the boxes along `inside` that don't exist yet" },
  },
  confirm:     ->(payload, ctx) {
    name = payload[:item].to_s.strip
    raise "nothing to add" if name.blank?

    inside = payload[:inside].to_s.strip
    next { summary: "Add #{name} to the top level?", resolved: { item: name, where: "the top level" } } if inside.blank?

    plan = Buddy::Inventory.plan(ctx.user, inside)
    found = plan[:found]
    missing = plan[:missing]
    where = [found && Buddy::Inventory.path_of(found), *missing].compact.join(" > ")

    if missing.any? && !payload[:make_boxes]
      place = found ? "inside #{Buddy::Inventory.path_of(found)}" : "in the inventory"
      raise "there's no #{missing.first.inspect} #{place} yet - make_boxes makes it"
    end

    # A path still to be made is walked again when it runs: an earlier call in
    # the same reply may be the one making it, and by then it's there.
    resolved = (
      if missing.any?
        { item: name, inside_path: inside, where: where, new_boxes: missing }
      else
        { item: name, parent_key: found.param_key, parent_name: found.name, where: where }
      end
    )
    { summary: "Add #{name} to #{where}?", resolved: resolved }
  },
  label:       ->(payload, _ctx) {
    lines = ["📦 #{payload[:where] || "the top level"}"]
    lines << payload[:notes].to_s if payload[:notes].present?
    { title: payload[:item].to_s, sub: lines.join("\n") }
  },
  merge_key:   ->(payload) {
    place = payload[:parent_key] || payload[:inside_path].to_s.downcase.strip
    "add_inventory_item:#{place}:#{payload[:item].to_s.downcase.strip}"
  },
  # A correction lands far more often than a genuine second copy of the same
  # thing in the same box - "no, put it in the tool cubes" is the same object
  # being filed once, and two rows for it is exactly the mess an inventory is
  # supposed to prevent.
  supersedes:  true,
  # Level 2: it files immediately as a pre-checked row and unticks straight
  # back off, the same as adding to a list.
  level:       2,
  execute:     ->(payload, ctx) {
    parent_key, made = payload[:parent_key], []
    if payload[:inside_path].present?
      parent, made = Buddy::Inventory.walk!(ctx.user, payload[:inside_path], create: true)
      parent_key = parent.param_key
    end

    box = ::Box.create!(
      user:        ctx.user,
      name:        payload[:item],
      parent_key:  parent_key,
      notes:       payload[:notes].presence,
      description: payload[:description].presence,
    )

    # Undo takes back the thing filed, never the boxes made on the way to it:
    # the next call in the same reply may have filed into them too.
    {
      box_key: box.param_key,
      item:    box.name,
      where:   payload[:where],
      made:    made.map(&:name),
      revert:  { op: "created", model: "Box", id: box.param_key, summary: "took #{box.name} back out of the inventory" },
    }
  },
  receipt:     ->(result, _ctx) {
    made = Array(result[:made] || result["made"])
    also = made.any? ? " (made #{made.join(" > ")})" : ""
    "Filed **#{result[:item]}** in #{result[:where]} — `##{result[:box_key]}`#{also} ✓"
  },
)
