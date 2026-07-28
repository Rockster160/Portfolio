Buddy::Tools.register(
  name:        :edit_agenda_item,
  description: <<~TXT,
    Edit an existing agenda item - change title, time, duration, or cancel
    it. Only include the fields that are changing. Use `cancelled=true` to
    cancel an event without deleting it. For v1, only edits local (non-
    Google-synced) items.
  TXT
  args: {
    item:      { type: :string,       required: true,  description: "Fuzzy title of the item to edit" },
    hint_date: { type: :string,       required: false, description: "Date hint (YYYY-MM-DD) for disambiguation" },
    title:     { type: :string,       required: false, description: "New title" },
    at:        { type: :iso_time,     required: false, description: "New start time (ISO)" },
    duration:  { type: :duration_min, required: false, description: "New duration in minutes" },
    location:  { type: :string,       required: false, description: "New place/venue" },
    cancelled: { type: :string,       required: false, description: "'true' to cancel" },
  },
  confirm: ->(payload, ctx) {
    item = ctx.resolve_agenda_item(payload[:item], hint_date: payload[:hint_date])
    raise "no agenda item matching #{payload[:item].inspect}" if item.nil?
    raise "cannot edit Google-synced items yet" if item.agenda.managed_externally?

    { summary: "Edit #{item.name}?", resolved: { agenda_item_id: item.id } }
  },
  label: ->(payload, ctx) {
    item = AgendaItem.find_by(id: payload[:agenda_item_id])
    base = item&.name || payload[:item].to_s
    diffs = []
    diffs << "title → #{payload[:title]}" if payload[:title].present?
    diffs << "time → #{payload[:at].in_time_zone(ctx.user.timezone).strftime('%a %-I:%M %p')}" if payload[:at].respond_to?(:strftime)
    diffs << "duration → #{payload[:duration]}m" if payload[:duration].present?
    diffs << "@ #{payload[:location]}" if payload[:location].present?
    diffs << "cancel" if payload[:cancelled] == "true"
    { title: base, sub: diffs.join("\n").presence }
  },
  execute: ->(payload, ctx) {
    item = AgendaItem.find(payload[:agenda_item_id])
    attrs = {}
    attrs[:name]     = payload[:title]    if payload[:title].present?
    attrs[:location] = payload[:location] if payload[:location].present?
    # `at` is an ISO string at execute time (JSON round-trip) — parse it.
    new_start = payload[:at].present? ? ctx.resolve_time(payload[:at]) : nil
    attrs[:start_at] = new_start if new_start
    if payload[:duration].present?
      base_start = attrs[:start_at] || item.start_at
      attrs[:end_at] = base_start + payload[:duration].to_i.minutes
    end
    attrs[:status] = :cancelled if payload[:cancelled] == "true"
    prior_name = item.name
    before     = attrs.keys.index_with { |k| item.public_send(k) }  # old values, for undo
    item.update!(attrs) unless attrs.empty?
    {
      agenda_item_id: item.id,
      updated_fields: attrs.keys,
      revert: { op: "updated", model: "AgendaItem", id: item.id, before: before, summary: "reverted #{prior_name}" },
    }
  },
  receipt: ->(result, _ctx) {
    item = AgendaItem.find_by(id: result[:agenda_item_id])
    "Updated #{item&.name || 'that item'} ✓"
  },
)
