Buddy::Tools.register(
  name:        :remove_list_item,
  description: <<~TXT,
    Remove an item from a list (soft-delete - matches the app's "check off"
    behavior). Use when the user says they finished something on a list or
    wants it gone.
  TXT
  args: {
    list: { type: :string, required: true, description: "List name" },
    item: { type: :string, required: true, description: "Item to remove" },
  },
  confirm: ->(payload, ctx) {
    list = ctx.resolve_list(payload[:list])
    raise "no list matching #{payload[:list].inspect}" if list.nil?

    { summary: "Remove #{payload[:item]} from #{list.name}?", resolved: { list_id: list.id, list_name: list.name } }
  },
  label: ->(payload, _ctx) { "Remove #{payload[:item]} from #{payload[:list_name]}" },
  merge_key: ->(payload) { "remove_list_item:#{payload[:list_id]}:#{payload[:item].to_s.downcase.strip}" },
  merge_label: ->(payload, count) { "#{count}× remove #{payload[:item]} from #{payload[:list_name]}" },
  execute: ->(payload, _ctx) {
    list = List.find(payload[:list_id])
    list.list_items.remove(payload[:item])
    { list_id: list.id, item_name: payload[:item] }
  },
  receipt: ->(result, _ctx) { "Removed #{result[:item_name]} ✓" },
)
