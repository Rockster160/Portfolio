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
    cancelled: { type: :string,       required: false, description: "'true' to cancel" },
  },
  confirm: ->(payload, ctx) {
    item = ctx.resolve_agenda_item(payload[:item], hint_date: payload[:hint_date])
    raise "no agenda item matching #{payload[:item].inspect}" if item.nil?
    raise "cannot edit Google-synced items yet" if item.agenda.managed_externally?

    { summary: "Edit #{item.title}?", resolved: { agenda_item_id: item.id } }
  },
  label: ->(payload, ctx) {
    item = AgendaItem.find_by(id: payload[:agenda_item_id])
    base = item&.title || payload[:item].to_s
    diffs = []
    diffs << "title → #{payload[:title]}" if payload[:title].present?
    diffs << "time → #{payload[:at].in_time_zone(ctx.user.timezone).strftime('%a %-I:%M %p')}" if payload[:at].respond_to?(:strftime)
    diffs << "duration → #{payload[:duration]}m" if payload[:duration].present?
    diffs << "cancel" if payload[:cancelled] == "true"
    "#{base}: #{diffs.join(', ')}"
  },
  execute: ->(payload, _ctx) {
    item = AgendaItem.find(payload[:agenda_item_id])
    attrs = {}
    attrs[:title]    = payload[:title]                              if payload[:title].present?
    attrs[:start_at] = payload[:at]                                 if payload[:at].respond_to?(:strftime)
    if payload[:duration].present? && attrs[:start_at]
      attrs[:end_at] = attrs[:start_at] + payload[:duration].to_i.minutes
    elsif payload[:duration].present?
      attrs[:end_at] = item.start_at + payload[:duration].to_i.minutes
    end
    attrs[:status] = :cancelled if payload[:cancelled] == "true"
    item.update!(attrs) unless attrs.empty?
    { agenda_item_id: item.id, updated_fields: attrs.keys }
  },
  receipt: ->(_result, ctx) {
    item = AgendaItem.find_by(id: ctx.proposal["payload"]&.dig("agenda_item_id"))
    "Updated #{item&.title || 'that item'} ✓"
  },
)
