Buddy::Tools.register(
  name:        :toggle_list_item,
  summary:     "Flip an item on a list: add it if it isn't there, take it off if it is.",
  description: <<~TXT,
    Puts the item on the list when it's missing and takes it off when it's
    there, deciding at the moment it runs. For "toggle X on the list", or a
    button or phrase that should flip an item each time it fires. The item
    comes back in the section it was in before.
  TXT
  feature:     :lists,
  args:        {
    list: { type: :string, required: true, description: "Fuzzy list name" },
    item: { type: :string, required: true, description: "The item, in their own words" },
  },
  confirm:     ->(payload, ctx) {
    list = ctx.resolve_list(payload[:list])
    raise "no list matching #{payload[:list].inspect}" if list.nil?

    name = Buddy::ListItemName.tidy(payload[:item], list: list)
    raise "nothing to toggle" if name.blank?

    { summary: "Toggle #{name} on #{list.name}?", resolved: { list_id: list.id, list_name: list.name, item: name } }
  },
  label:       ->(payload, _ctx) { { title: "Toggle #{payload[:item]}", sub: "📋 #{payload[:list_name]}" } },
  merge_key:   ->(payload) { "toggle_list_item:#{payload[:list_id]}:#{payload[:item].to_s.downcase.strip}" },
  level:       1,
  execute:     ->(payload, _ctx) {
    list = List.find(payload[:list_id])
    list.list_items.toggle(payload[:item])
    item = list.list_items.by_formatted_name(payload[:item])
    { item_name: payload[:item], list_name: list.name, on_list: item.present? }
  },
  receipt:     ->(result, _ctx) {
    if result[:on_list]
      "Added #{result[:item_name]} to #{result[:list_name]} ✓"
    else
      "Took #{result[:item_name]} off #{result[:list_name]} ✓"
    end
  },
)
