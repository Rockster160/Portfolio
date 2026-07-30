Buddy::Tools.register(
  name:        :edit_list_item,
  description: <<~TXT,
    Edit a list item - rename it, flag it important, mark it permanent, or
    change where it sits. Only include the fields that are changing.

    `section` is a real heading on the list (see the `lists` context) and
    moves the item there. `category` is a freeform label on the item itself
    (who or what it's for) and is independent of the section. Prefer a
    section when one matches; `category` only holds a placement when no
    section by that name exists.
  TXT
  args:        {
    list:      { type: :string, required: true, description: "List name" },
    item:      { type: :string, required: true, description: "Current item name" },
    rename:    { type: :string, required: false, description: "New name" },
    important: { type: :string, required: false, description: "'true' or 'false'" },
    permanent: { type: :string, required: false, description: "'true' or 'false'" },
    section:   { type: :string, required: false, description: "Section to move it to - use an exact name from `lists`" },
    category:  { type: :string, required: false, description: "Freeform label on the item (who/what it's for), not a placement" },
  },
  confirm:     ->(payload, ctx) {
    item = ctx.resolve_list_item(payload[:list], payload[:item])
    raise "no list item matching #{payload[:item].inspect} on #{payload[:list].inspect}" if item.nil?

    resolved = { list_item_id: item.id, list_name: item.list.name }
    section  = payload[:section].presence
    category = payload[:category].presence

    # Same resolution as add_list_item: a placement lands in a real section
    # when one matches, and `category` doubling as a placement still works.
    match = item.list.sections.where_soft_name(section || category).first if section || category
    if match
      resolved[:section_id]   = match.id
      resolved[:section_name] = match.name
      category = nil if section.nil?
    elsif category.nil?
      category = section
    end
    # Set unconditionally: `resolved` merges OVER the raw payload, so a category
    # that just became the section has to be written back as nil to clear it.
    resolved[:category] = category

    # A category that was standing in for the placement is redundant once the
    # item really lives in that section. A category that means something else
    # ("Mom") has to survive the move, so only the matching one gets dropped.
    soft = ->(str) { str.to_s.gsub(/[^\w\s\d]/, "").downcase.squish }
    resolved[:clear_category] = true if match && item.category.present? && soft.call(item.category) == soft.call(match.name)

    { summary: "Edit #{item.name} on #{payload[:list]}?", resolved: resolved }
  },
  label:       ->(payload, _ctx) {
    diffs = []
    diffs << "→ #{payload[:rename]}" if payload[:rename].present?
    diffs << "important #{payload[:important]}" if payload.key?(:important)
    diffs << "permanent #{payload[:permanent]}" if payload.key?(:permanent)
    diffs << "› #{payload[:section_name]}" if payload[:section_name].present?
    diffs << "🏷️ #{payload[:category]}" if payload[:category].present?
    { title: payload[:item].to_s, sub: diffs.join("\n").presence }
  },
  execute:     ->(payload, _ctx) {
    item = ListItem.find(payload[:list_item_id])
    attrs = {}
    attrs[:name]      = payload[:rename]                     if payload[:rename].present?
    attrs[:important] = payload[:important] == "true"        if payload.key?(:important)
    attrs[:permanent] = payload[:permanent] == "true"        if payload.key?(:permanent)
    attrs[:section_id] = payload[:section_id] if payload[:section_id].present?
    attrs[:category]   = payload[:category]   if payload[:category].present?
    attrs[:category]   = nil                  if payload[:clear_category] && payload[:category].blank?
    item.update!(attrs) unless attrs.empty?
    { list_item_id: item.id }
  },
  receipt:     ->(_result, _ctx) { "Updated list item ✓" },
)
