Buddy::Tools.register(
  name:        :remove_list_item,
  description: <<~TXT,
    Remove an item from a list (soft-delete - matches the app's "check off"
    behavior). Use when the user says they finished something on a list or
    wants it gone.
  TXT
  feature:     :lists,
  args:        {
    list: { type: :string, required: true, description: "List name" },
    item: { type: :string, required: true, description: "Item to remove" },
  },
  confirm:     ->(payload, ctx) {
    list = ctx.resolve_list(payload[:list])
    raise "no list matching #{payload[:list].inspect}" if list.nil?

    { summary: "Remove #{payload[:item]} from #{list.name}?", resolved: { list_id: list.id, list_name: list.name } }
  },
  label:       ->(payload, _ctx) { { title: "Remove #{payload[:item]}", sub: "📋 #{payload[:list_name]}" } },
  merge_key:   ->(payload) { "remove_list_item:#{payload[:list_id]}:#{payload[:item].to_s.downcase.strip}" },
  # Removing the same item again is the same act, not a second one, so the
  # later row replaces the earlier rather than stacking two undo handles on one
  # record.
  supersedes:  true,
  merge_label: ->(payload, count) { { title: "Remove #{count}× #{payload[:item]}", sub: "📋 #{payload[:list_name]}" } },
  # Level 2: removes immediately as a pre-checked row; unchecking re-adds it.
  level:       2,
  execute:     ->(payload, _ctx) {
    list = List.find(payload[:list_id])
    list.list_items.remove(payload[:item])
    {
      list_id:   list.id,
      item_name: payload[:item],
      revert:    { op: "recreated", model: "ListItem", attrs: { list_id: list.id, name: payload[:item] }, summary: "put #{payload[:item]} back on #{list.name}" },
    }
  },
  receipt:     ->(result, _ctx) { "Removed #{result[:item_name]} ✓" },
)
