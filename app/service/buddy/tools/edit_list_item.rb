Buddy::Tools.register(
  name:        :edit_list_item,
  description: <<~TXT,
    Edit a list item - rename it, flag it important, mark it permanent, or
    change its category. Only include the fields that are changing.
  TXT
  args: {
    list:      { type: :string, required: true, description: "List name" },
    item:      { type: :string, required: true, description: "Current item name" },
    rename:    { type: :string, required: false, description: "New name" },
    important: { type: :string, required: false, description: "'true' or 'false'" },
    permanent: { type: :string, required: false, description: "'true' or 'false'" },
    category:  { type: :string, required: false, description: "New category" },
  },
  confirm: ->(payload, ctx) {
    item = ctx.resolve_list_item(payload[:list], payload[:item])
    raise "no list item matching #{payload[:item].inspect} on #{payload[:list].inspect}" if item.nil?

    { summary: "Edit #{item.name} on #{payload[:list]}?", resolved: { list_item_id: item.id, list_name: item.list.name } }
  },
  label: ->(payload, _ctx) {
    diffs = []
    diffs << "→ #{payload[:rename]}" if payload[:rename].present?
    diffs << "important #{payload[:important]}" if payload.key?(:important)
    diffs << "permanent #{payload[:permanent]}" if payload.key?(:permanent)
    diffs << "cat #{payload[:category]}" if payload[:category].present?
    { title: payload[:item].to_s, sub: diffs.join("\n").presence }
  },
  execute: ->(payload, _ctx) {
    item = ListItem.find(payload[:list_item_id])
    attrs = {}
    attrs[:name]      = payload[:rename]                     if payload[:rename].present?
    attrs[:important] = payload[:important] == "true"        if payload.key?(:important)
    attrs[:permanent] = payload[:permanent] == "true"        if payload.key?(:permanent)
    attrs[:category]  = payload[:category]                   if payload[:category].present?
    item.update!(attrs) unless attrs.empty?
    { list_item_id: item.id }
  },
  receipt: ->(_result, ctx) { "Updated list item ✓" },
)
