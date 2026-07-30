Buddy::Tools.register(
  name:        :add_list_item,
  description: <<~TXT,
    Add an item to one of the user's lists. Use for grocery items, todos,
    anything they want tracked as a list entry. If the list doesn't exist,
    tell the user which lists ARE available - don't invent one.

    Pass `category` when they say WHERE on the list it belongs - a store, a
    section, an aisle ("add sanitizer under Harmon's", "put milk in dairy").
    Set it here rather than adding first and editing after.

    Use their exact wording for `item`, including any qualifier that tells
    them why it's on the list ("sanitizer for hike", not "sanitizer"). Match
    the capitalization style of the list's existing items.
  TXT
  args:        {
    list:     { type: :string, required: true,  description: "Fuzzy list name" },
    item:     { type: :string, required: true,  description: "Item to add, in their own words" },
    category: { type: :string, required: false, description: "Section/store to file it under, if they said one" },
  },
  confirm:     ->(payload, ctx) {
    list = ctx.resolve_list(payload[:list])
    raise "no list matching #{payload[:list].inspect}" if list.nil?

    where = payload[:category].presence ? " under #{payload[:category]}" : ""
    { summary: "Add #{payload[:item]} to #{list.name}#{where}?", resolved: { list_id: list.id, list_name: list.name } }
  },
  label:       ->(payload, _ctx) {
    sub = ["📋 #{payload[:list_name]}", payload[:category].presence].compact.join(" · ")
    { title: payload[:item].to_s, sub: sub }
  },
  merge_key:   ->(payload) { "add_list_item:#{payload[:list_id]}:#{payload[:item].to_s.downcase.strip}" },
  merge_label: ->(payload, count) { { title: "#{count}× #{payload[:item]}", sub: "📋 #{payload[:list_name]}" } },
  # Level 2: adds immediately as a pre-checked row; unchecking soft-removes it.
  level:       2,
  execute:     ->(payload, _ctx) {
    list = List.find(payload[:list_id])
    item = list.list_items.add(payload[:item])
    # `add` doesn't take a category, so set it on the row it hands back rather
    # than making the model add-then-edit (which it can't reliably do in one
    # turn, and which used to make it claim a category it never applied).
    item.update(category: payload[:category]) if item&.id && payload[:category].present?

    out = { list_item_id: item&.id, item_name: payload[:item], list_name: list.name, category: payload[:category] }
    if item&.id
      out[:revert] = { op: "created", model: "ListItem", id: item.id, summary: "removed #{payload[:item]} from #{list.name}" }
    end
    out
  },
  receipt:     ->(result, _ctx) {
    where = result[:category].presence ? " under #{result[:category]}" : ""
    "Added #{result[:item_name]} to #{result[:list_name]}#{where} ✓"
  },
)
