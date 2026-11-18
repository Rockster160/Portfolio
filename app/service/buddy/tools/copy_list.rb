Buddy::Tools.register(
  name:        :copy_list,
  summary:     "Copy every item on one of their lists onto another list.",
  description: <<~TXT,
    Copy everything on one list onto another, in one go: "put everything from
    Tacos on the groceries", "import Camping into Packing", "add the Costco
    list to Groceries". The source list keeps its items.

    `from` is the list the items come off, `to` is the list they land on. Both
    are fuzzy list names from `lists`.

    Items already on `to` are left alone rather than doubled. An item sitting
    in a section lands in the section of the same name on `to` when there is
    one; its category comes with it.

    This is the whole list. A single item, or a few named ones, is an add.
  TXT
  feature:     :lists,
  args:        {
    from: { type: :string, required: true, description: "Fuzzy name of the list to copy from" },
    to:   { type: :string, required: true, description: "Fuzzy name of the list to copy onto" },
  },
  confirm:     ->(payload, ctx) {
    from = ctx.resolve_list(payload[:from])
    raise "no list matching #{payload[:from].inspect}" if from.nil?

    to = ctx.resolve_list(payload[:to])
    raise "no list matching #{payload[:to].inspect}" if to.nil?
    raise "#{from.name} and #{to.name} are the same list" if from.id == to.id
    raise "#{from.name} has nothing on it to copy" if from.list_items.none?

    {
      summary:  "Copy everything on #{from.name} onto #{to.name}?",
      resolved: { from_id: from.id, from_name: from.name, to_id: to.id, to_name: to.name },
    }
  },
  label:       ->(payload, _ctx) {
    { title: "Copy #{payload[:from_name]}", sub: "📋 #{payload[:from_name]} → #{payload[:to_name]}" }
  },
  merge_key:   ->(payload) { "copy_list:#{payload[:from_id]}:#{payload[:to_id]}" },
  supersedes:  true,
  # Level 2: copies immediately as a pre-checked row; unchecking takes back
  # exactly the items this copy put there.
  level:       2,
  execute:     ->(payload, _ctx) {
    from = List.find(payload[:from_id])
    to   = List.find(payload[:to_id])

    summary = "took the #{from.name} items back off #{to.name}"
    added    = []
    skipped  = []

    # `add` files each new item at the top, so walking the source bottom-up
    # leaves the copies in the same order they had on the source.
    from.list_items.includes(:section).reverse_each { |source|
      if to.list_items.by_formatted_name(source.name)
        skipped << source.name
        next
      end

      item = to.list_items.add(source.name)
      next unless item&.id

      section = source.section && to.sections.where_soft_name(source.section.name).first
      attrs = {}
      attrs[:section_id] = section.id if section
      attrs[:category]   = source.category if source.category.present?
      item.update(attrs) if attrs.any?
      added << item
    }

    {
      from_name: from.name,
      to_name:   to.name,
      added:     added.map(&:name),
      skipped:   skipped,
      reverts:   added.map { |item| { op: "created", model: "ListItem", id: item.id, summary: summary } },
    }
  },
  receipt:     ->(result, _ctx) {
    added   = Array(result[:added]).size
    skipped = Array(result[:skipped]).size
    already = skipped.positive? ? " (#{skipped} already there)" : ""
    next "Everything on #{result[:from_name]} is already on #{result[:to_name]} ✓" if added.zero?

    "Copied #{added} #{"item".pluralize(added)} from #{result[:from_name]} to #{result[:to_name]}#{already} ✓"
  },
)
