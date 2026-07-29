Buddy::Tools.register(
  name:        :add_list_item,
  description: <<~TXT,
    Add an item to one of the user's lists. Use for grocery items, todos,
    anything they want tracked as a list entry. If the list doesn't exist,
    tell the user which lists ARE available - don't invent one.
  TXT
  args:        {
    list: { type: :string, required: true, description: "Fuzzy list name" },
    item: { type: :string, required: true, description: "Item to add" },
  },
  confirm:     ->(payload, ctx) {
    list = ctx.resolve_list(payload[:list])
    raise "no list matching #{payload[:list].inspect}" if list.nil?

    { summary: "Add #{payload[:item]} to #{list.name}?", resolved: { list_id: list.id, list_name: list.name } }
  },
  label:       ->(payload, _ctx) { { title: payload[:item].to_s, sub: "📋 #{payload[:list_name]}" } },
  merge_key:   ->(payload) { "add_list_item:#{payload[:list_id]}:#{payload[:item].to_s.downcase.strip}" },
  merge_label: ->(payload, count) { { title: "#{count}× #{payload[:item]}", sub: "📋 #{payload[:list_name]}" } },
  # Level 2: adds immediately as a pre-checked row; unchecking soft-removes it.
  level:       2,
  execute:     ->(payload, _ctx) {
    list = List.find(payload[:list_id])
    item = list.list_items.add(payload[:item])
    out = { list_item_id: item&.id, item_name: payload[:item], list_name: list.name }
    if item&.id
      out[:revert] = { op: "created", model: "ListItem", id: item.id, summary: "removed #{payload[:item]} from #{list.name}" }
    end
    out
  },
  receipt:     ->(result, _ctx) { "Added #{result[:item_name]} to #{result[:list_name]} ✓" },
)
