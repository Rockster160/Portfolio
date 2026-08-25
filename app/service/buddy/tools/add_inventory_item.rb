Buddy::Tools.register(
  name:        :add_inventory_item,
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
    Stove", not "the camp stove I got from Dave". `inside` is the box it goes
    in, by name ("camping tote", "tool cubes"); leave it off only when they're
    starting something that sits on its own at the top level, like a room or a
    shelf.

    A box and an item are the same kind of row here, and the difference is
    only whether anything is inside it. So starting a new bin is this tool
    with nothing in `inside`, or with the room it lives in, and then the
    things go in with `inside` naming the bin. Nothing is created implicitly:
    if `inside` doesn't match a box that exists, you'll be told, and the right
    answer is to ask where it should go rather than inventing a shelf.

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
  },
  confirm:     ->(payload, ctx) {
    name = payload[:item].to_s.strip
    raise "nothing to add" if name.blank?

    parent = payload[:inside].present? ? Buddy::Inventory.resolve!(ctx.user, payload[:inside], verb: "add to", arg: :inside) : nil
    where  = parent ? Buddy::Inventory.path_of(parent) : "the top level"

    {
      summary:  "Add #{name} to #{where}?",
      resolved: { item: name, parent_key: parent&.param_key, parent_name: parent&.name, where: where },
    }
  },
  label:       ->(payload, _ctx) {
    lines = ["📦 #{payload[:where] || "the top level"}"]
    lines << payload[:notes].to_s if payload[:notes].present?
    { title: payload[:item].to_s, sub: lines.join("\n") }
  },
  merge_key:   ->(payload) { "add_inventory_item:#{payload[:parent_key]}:#{payload[:item].to_s.downcase.strip}" },
  # A correction lands far more often than a genuine second copy of the same
  # thing in the same box - "no, put it in the tool cubes" is the same object
  # being filed once, and two rows for it is exactly the mess an inventory is
  # supposed to prevent.
  supersedes:  true,
  # Level 2: it files immediately as a pre-checked row and unticks straight
  # back off, the same as adding to a list.
  level:       2,
  execute:     ->(payload, ctx) {
    box = ::Box.create!(
      user:        ctx.user,
      name:        payload[:item],
      parent_key:  payload[:parent_key],
      notes:       payload[:notes].presence,
      description: payload[:description].presence,
    )

    {
      box_key: box.param_key,
      item:    box.name,
      where:   payload[:where],
      revert:  { op: "created", model: "Box", id: box.param_key, summary: "took #{box.name} back out of the inventory" },
    }
  },
  receipt:     ->(result, _ctx) { "Filed **#{result[:item]}** in #{result[:where]} — `##{result[:box_key]}` ✓" },
)
