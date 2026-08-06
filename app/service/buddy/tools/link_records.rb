Buddy::Tools.register(
  name:        :link_records,
  description: <<~TXT,
    Wire two things together so one following the other stops being manual. Use
    it when they describe a pairing: "logging coffee should tick off the coffee
    chore", "when I finish the RX chore take it off the Chores list", "taking my
    Cymbalta should check off the Cymbalta task".

    **The cascade only ever runs downhill:**

        logged event  ->  chore  ->  agenda task  ->  list item

    So `source` must come before `target` in that order. Logging an event
    completes a chore; completing a chore ticks off an agenda task and takes an
    item off a list. The reverse never happens - completing a chore does NOT
    write an event, and checking something off a list does NOT touch the chore.
    If they ask for one of those, say it runs the wrong way rather than making
    a link that will be refused.

    The two ends do NOT need the same name, and usually don't: chore "Focus"
    pairs with event "D-Amphetamine", chore "Check Softener Salt" with list item
    "Check Salt".

    `source_notes` narrows an event by its notes, which is the only thing
    separating several chores that share one event name ("Fae" with notes
    "Litter" vs "Food"). `target_list` says which list, and is required for a
    list item.

    `match` decides how forgiving the source is: `exactly` (default),
    `starts_with`, or `contains`. Reach for a looser one when the thing is typed
    freehand and varies - a medication logged with its dosage matches on
    `contains` with just the drug name, and then keeps matching when the dose
    changes or somebody misspells it.

    `ask_who` is for a chore more than one person in the house does: instead of
    crediting whoever logged it, it raises a prompt asking who.
  TXT
  args:        {
    source:       { type: :enum, required: true, values: %i[event chore], description: "What happens first" },
    source_name:  { type: :string, required: true, description: "Name of the event or chore that fires" },
    source_notes: { type: :string, required: false, description: "Narrow an event by its notes" },
    target:       {
      type:        :enum,
      required:    true,
      values:      %i[chore agenda list_item],
      description: "What follows - must come after source in the cascade",
    },
    target_name:  { type: :string, required: true, description: "Name of the chore, agenda task, or list item" },
    target_list:  { type: :string, required: false, description: "Which list (required for a list item)" },
    match:        {
      type:        :enum,
      required:    false,
      values:      %i[exactly starts_with contains],
      description: "How forgiving the source match is. Default exactly",
    },
    ask_who:      {
      type:        :boolean,
      required:    false,
      default:     false,
      description: "Ask who did it rather than crediting whoever logged it",
    },
  },
  confirm:     ->(payload, ctx) {
    src = payload[:source].to_s
    tgt = payload[:target].to_s
    raise "the cascade runs #{RecordLink::KINDS.keys.join(" -> ")}, so #{src} can't follow #{tgt}" unless
      RecordLink::RANK.fetch(src.to_sym, 99) < RecordLink::RANK.fetch(tgt.to_sym, 99)
    raise "a list item link needs to say which list" if tgt == "list_item" && payload[:target_list].to_s.strip.empty?

    # Resolve the chore end against real chores so a fuzzy name lands on the
    # record rather than being stored as typed and never matching.
    source_name = Buddy::LinkNames.resolve(payload[:source_name], src, ctx)
    target_name = Buddy::LinkNames.resolve(payload[:target_name], tgt, ctx)
    raise "which #{src}?" if source_name.empty?
    raise "which #{tgt}?" if target_name.empty?

    {
      summary:  "Link #{src.humanize.downcase} **#{source_name}** → #{tgt.humanize.downcase} **#{target_name}**?",
      resolved: { source_name: source_name, target_name: target_name },
    }
  },
  label:       ->(payload, _ctx) {
    tail = [payload[:target_name], payload[:target_list].presence && "on #{payload[:target_list]}"].compact.join(" ")
    { title: "🔗 #{payload[:source_name]} → #{tail}", sub: (payload[:source_notes].presence && "notes: #{payload[:source_notes]}") }
  },
  merge_key:   ->(payload) {
    "link_records:#{payload[:source]}:#{payload[:source_name].to_s.downcase}:" \
      "#{payload[:target]}:#{payload[:target_name].to_s.downcase}"
  },
  supersedes:  true,
  level:       2,
  execute:     ->(payload, ctx) {
    mode  = (payload[:match].presence || :exactly).to_sym
    # The looser mode goes on whichever field is the freehand one. Notes are
    # freehand when present; otherwise it's the name.
    notes = payload[:source_notes].presence
    attrs = {
      source_kind:        payload[:source],
      source_name:        payload[:source_name],
      source_scope:       notes,
      source_name_match:  notes ? :exactly : mode,
      source_scope_match: notes ? mode : :exactly,
      target_kind:        payload[:target],
      target_name:        payload[:target_name],
      target_scope:       payload[:target_list].presence,
      # `!!` because the cast returns nil for an absent arg, and the column is
      # NOT NULL. ask_who only means anything on a chore target.
      ask_who:            !!(ActiveModel::Type::Boolean.new.cast(payload[:ask_who]) && payload[:target].to_s == "chore"),
    }

    existing = RecordLink.where(user_id: ctx.user.id, source_kind: attrs[:source_kind], target_kind: attrs[:target_kind])
      .where("LOWER(source_name) = ? AND LOWER(target_name) = ?",
        attrs[:source_name].to_s.downcase, attrs[:target_name].to_s.downcase)
      .first

    if existing
      before = existing.slice(:source_scope, :source_name_match, :source_scope_match, :target_scope, :ask_who)
      existing.update!(attrs.except(:source_kind, :target_kind))
      next {
        summary: existing.sentence,
        verb:    "Updated",
        revert:  {
          op:      "updated",
          model:   "RecordLink",
          id:      existing.id,
          before:  before,
          summary: "put that link back the way it was",
        },
      }
    end

    created = RecordLink.create!(attrs.merge(user: ctx.user))
    {
      summary: created.sentence,
      verb:    "Linked",
      revert:  { op: "created", model: "RecordLink", id: created.id, summary: "unlinked those again" },
    }
  },
  receipt:     ->(result, _ctx) { "#{result[:verb]}: #{result[:summary]} ✓" },
)
