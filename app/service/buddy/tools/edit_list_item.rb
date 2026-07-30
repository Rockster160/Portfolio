Buddy::Tools.register(
  name:        :edit_list_item,
  description: <<~TXT,
    Edit a list item - rename it, flag it important, mark it permanent, or
    move it into a different section/category. Only include the fields that
    are changing. `category` matches a real SECTION on the list (see the
    `lists` context) and moves the item there when one fits; otherwise it's
    kept as a plain label.
  TXT
  args:        {
    list:      { type: :string, required: true, description: "List name" },
    item:      { type: :string, required: true, description: "Current item name" },
    rename:    { type: :string, required: false, description: "New name" },
    important: { type: :string, required: false, description: "'true' or 'false'" },
    permanent: { type: :string, required: false, description: "'true' or 'false'" },
    category:  { type: :string, required: false, description: "Section to file it under, or a plain category" },
  },
  confirm:     ->(payload, ctx) {
    item = ctx.resolve_list_item(payload[:list], payload[:item])
    raise "no list item matching #{payload[:item].inspect} on #{payload[:list].inspect}" if item.nil?

    resolved = { list_item_id: item.id, list_name: item.list.name }
    if payload[:category].present?
      section = item.list.sections.where_soft_name(payload[:category])
      if section.one?
        resolved[:section_id]   = section.first.id
        resolved[:section_name] = section.first.name
      end
    end
    { summary: "Edit #{item.name} on #{payload[:list]}?", resolved: resolved }
  },
  label:       ->(payload, _ctx) {
    diffs = []
    diffs << "→ #{payload[:rename]}" if payload[:rename].present?
    diffs << "important #{payload[:important]}" if payload.key?(:important)
    diffs << "permanent #{payload[:permanent]}" if payload.key?(:permanent)
    diffs << "section #{payload[:section_name]}" if payload[:section_name].present?
    diffs << "cat #{payload[:category]}" if payload[:section_name].blank? && payload[:category].present?
    { title: payload[:item].to_s, sub: diffs.join("\n").presence }
  },
  execute:     ->(payload, _ctx) {
    item = ListItem.find(payload[:list_item_id])
    attrs = {}
    attrs[:name]      = payload[:rename]                     if payload[:rename].present?
    attrs[:important] = payload[:important] == "true"        if payload.key?(:important)
    attrs[:permanent] = payload[:permanent] == "true"        if payload.key?(:permanent)
    if payload[:section_id].present?
      attrs[:section_id] = payload[:section_id]
      attrs[:category]   = nil
    elsif payload[:category].present?
      attrs[:category] = payload[:category]
    end
    item.update!(attrs) unless attrs.empty?
    { list_item_id: item.id }
  },
  receipt:     ->(_result, _ctx) { "Updated list item ✓" },
)
