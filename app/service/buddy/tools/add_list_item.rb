Buddy::Tools.register(
  name:        :add_list_item,
  description: <<~TXT,
    Add an item to one of the user's lists. Use for grocery items, todos,
    anything they want tracked as a list entry. If the list doesn't exist,
    tell the user which lists ARE available - don't invent one.

    WHERE it goes on the list is `section`, and sections are the real
    structure: a store, an aisle, a heading ("at Costco", "under Harmon's",
    "in Dairy"). Check the `lists` context for the sections that exist and
    pass one of those names exactly. Only reach for `category` to hold the
    placement when nothing there matches.

    `category` is a freeform label on the item itself - who it's for, what
    it's for ("Mom", "camping", "party"). It is NOT a fallback spelling of
    the section, and the two are independent: "a chicken salad for mom at
    Costco" is `section: "Costco"`, `category: "Mom"`. When a qualifier
    applies to a whole run of items, put it on each of them.

    Use their exact wording for `item`, minus any leading article - a list
    reads "Chicken salad for mom", never "a chicken salad for mom". Keep the
    qualifier that says why it's on the list ("sanitizer for hike", not
    "sanitizer"). Match the capitalization style of the list's existing items.
  TXT
  args:        {
    list:     { type: :string, required: true,  description: "Fuzzy list name" },
    item:     { type: :string, required: true,  description: "Item to add, in their own words" },
    section:  { type: :string, required: false, description: "Section/heading on the list to file it under - use an exact name from `lists`" },
    category: { type: :string, required: false, description: "Freeform label on the item (who/what it's for), not a placement" },
  },
  confirm:     ->(payload, ctx) {
    list = ctx.resolve_list(payload[:list])
    raise "no list matching #{payload[:list].inspect}" if list.nil?

    name = Buddy::ListItemName.tidy(payload[:item], list: list)
    raise "nothing to add" if name.blank?

    resolved = { list_id: list.id, list_name: list.name, item: name }
    section  = payload[:section].presence
    category = payload[:category].presence

    # Sections are the real structure, so a placement lands in one whenever it
    # can. `category` carrying the placement is the older shape and still works:
    # if what they passed names a real section, that IS the section they meant.
    match = list.sections.where_soft_name(section || category).first if section || category
    if match
      resolved[:section_id]   = match.id
      resolved[:section_name] = match.name
      category = nil if section.nil?
    elsif category.nil?
      # No section by that name, so the placement degrades to a plain label.
      category = section
    end
    # Set unconditionally: `resolved` merges OVER the raw payload, so a category
    # that just became the section has to be written back as nil to clear it.
    resolved[:category] = category

    where = [resolved[:section_name], resolved[:category]].compact.join(", ")
    under = where.present? ? " under #{where}" : ""
    { summary: "Add #{name} to #{list.name}#{under}?", resolved: resolved }
  },
  # Section and category answer different questions, so they get different
  # marks: `›` reads as a place inside the list, `🏷️` as a tag on the item.
  # Rendering both as "Shopping · Costco" left it ambiguous which one Costco was.
  label:       ->(payload, _ctx) {
    lines = ["📋 #{[payload[:list_name], payload[:section_name].presence].compact.join(" › ")}"]
    lines << "🏷️ #{payload[:category]}" if payload[:category].present?
    { title: payload[:item].to_s, sub: lines.join("\n") }
  },
  merge_key:   ->(payload) { "add_list_item:#{payload[:list_id]}:#{payload[:item].to_s.downcase.strip}" },
  # An item is on a list once, and `ListItem.add` revives the same row rather
  # than making a second, so "that should've been under Costco" is a correction
  # of the row above rather than a second trail mix. Retire the old one.
  supersedes:  true,
  merge_label: ->(payload, count) {
    { title: "#{count}× #{payload[:item]}", sub: "📋 #{[payload[:list_name], payload[:section_name].presence].compact.join(" › ")}" }
  },
  # Level 2: adds immediately as a pre-checked row; unchecking soft-removes it.
  level:       2,
  execute:     ->(payload, _ctx) {
    list = List.find(payload[:list_id])
    item = list.list_items.add(payload[:item])
    # `add` doesn't take a section/category, so set them on the row it hands
    # back rather than making the model add-then-edit (which it can't reliably
    # do in one turn, and which used to make it claim a category it never
    # applied). A resolved section_id files it into the real Section (mirrors
    # how ListItemsController#create handles a `[Section]` name); the category
    # is an independent label and rides alongside.
    if item&.id
      attrs = {}
      attrs[:section_id] = payload[:section_id] if payload[:section_id].present?
      attrs[:category]   = payload[:category]   if payload[:category].present?
      item.update(attrs) if attrs.any?
    end

    out = {
      list_item_id: item&.id,
      item_name:    payload[:item],
      list_name:    list.name,
      section_name: payload[:section_name],
      category:     payload[:category],
    }
    if item&.id
      out[:revert] = { op: "created", model: "ListItem", id: item.id, summary: "removed #{payload[:item]} from #{list.name}" }
    end
    out
  },
  receipt:     ->(result, _ctx) {
    where = result[:section_name].presence ? " under #{result[:section_name]}" : ""
    tag   = result[:category].presence ? " (#{result[:category]})" : ""
    "Added #{result[:item_name]} to #{result[:list_name]}#{where}#{tag} ✓"
  },
)
