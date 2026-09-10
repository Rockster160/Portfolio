Buddy::Tools.register(
  name:        :complete_chore,
  description: <<~TXT,
    Mark a chore as done. Use this whenever the user says they finished a
    household task. `chore` is a fuzzy name and will match against the
    user's accessible chores. Supports `count=N` when the same chore
    should be marked done multiple times (e.g. drank water 5x).

    Pass `at` when the user says they finished at a PAST time — accepts
    natural phrasing like "an hour ago", "this morning", "8:15am", or an
    ISO timestamp. Omit `at` (or use "now") when they just finished. The
    non-default time gets surfaced on the confirmation row so it's clear
    what will be recorded.

    Pass `credit_to` — a household member's first name — when somebody ELSE
    did the work and they're telling you about it. The pebbles, the streak
    and that person's own automations all land on them, and the row records
    that this is who marked it. Leave it off whenever the person talking to
    you is the one who did it, which is nearly every time. Who a chore is
    ASSIGNED to is not who to credit: anyone can do anyone's chore, and this
    argument is for who actually did it.

    To change a completion that's already recorded — attach the note you
    missed, correct the time — use `edit_chore_completion`, not a second
    `complete_chore`.
  TXT
  feature:     :chores,
  args:        {
    chore:     { type: :string, required: true,  description: "Fuzzy chore name" },
    note:      { type: :string, required: false, description: "Optional note captured on the completion" },
    at:        { type: :string, required: false, description: "When it was actually done - past time expression or ISO timestamp. Omit for 'now'." },
    credit_to: { type: :string, required: false, description: "Household member's first name when THEY did it. Omit when the person speaking did it." },
  },
  confirm:     ->(payload, ctx) {
    chore = ctx.resolve_chore(payload[:chore])
    ctx.no_chore!(payload[:chore]) if chore.nil?

    credit = ctx.resolve_household_user(payload[:credit_to]) if payload[:credit_to].present?
    raise "nobody in the house goes by #{payload[:credit_to].inspect}" if payload[:credit_to].present? && credit.nil?

    # A fuzzy name lands on the container when a chore has been split per
    # person ("Teeth" holding one Teeth each), and a completion on the
    # container ticks nobody's card. Down one level HERE, so the id every stage
    # after this one reads - label, merge key, execute, receipt, undo - is the
    # chore that actually gets the row. Resolved for whoever is being CREDITED:
    # their half is the one that has to read done.
    chore = chore.completion_leaf_for(credit || ctx.user)
    resolved = { chore_id: chore.id }
    resolved[:credit_user_id] = credit.id if credit && credit.id != ctx.user.id
    if payload[:at].present?
      parsed = Buddy::TimeParser.parse_past(payload[:at], user: ctx.user)
      raise "couldn't parse time #{payload[:at].inspect}" if parsed.nil?

      resolved[:completed_at] = parsed.iso8601
    end

    who_str  = resolved[:credit_user_id] ? " for #{credit.first_name}" : ""
    when_str = resolved[:completed_at] ? " (at #{Buddy::TimeParser.friendly(resolved[:completed_at], user: ctx.user)})" : ""
    { summary: "Mark #{chore.name} done#{who_str}#{when_str}?", resolved: resolved }
  },
  label:       ->(payload, ctx) {
    chore = Chore.find_by(id: payload[:chore_id])
    title = chore&.name || payload[:chore].to_s

    subs = []
    credit = User.find_by(id: payload[:credit_user_id]) if payload[:credit_user_id].present?
    if credit
      # Who gets the points is the one thing about this row a person would want
      # to catch before it lands, so it displaces the assignee line below -
      # naming both would read as a contradiction on a chore that sits on
      # somebody else's name.
      subs << "credited to #{credit.first_name}"
    elsif chore&.assigned? && chore.assigned_to_user_id != ctx.user.id
      subs << "for #{chore.assigned_to_user&.first_name}"
    end
    subs << "📝 #{payload[:note]}" if payload[:note].present?
    if payload[:completed_at].present?
      subs << "at #{Buddy::TimeParser.friendly(payload[:completed_at], user: ctx.user)}"
    end

    { title: title, sub: subs.join("\n").presence }
  },
  # `note` is part of the key so "2 water with a note" and "3 water without one"
  # stay two separate rows/counts instead of collapsing into one - completions
  # that differ only in count still merge, ones that differ in note don't. Same
  # for who is credited: two people doing the same chore is two rows.
  merge_key:   ->(payload) {
    "complete_chore:#{payload[:chore_id]}:#{payload[:completed_at]}:#{payload[:note]}:#{payload[:credit_user_id]}"
  },
  merge_label: ->(payload, count) {
    chore = Chore.find_by(id: payload[:chore_id])
    title = "#{count}× #{chore&.name || payload[:chore]}"
    subs = []
    credit = User.find_by(id: payload[:credit_user_id]) if payload[:credit_user_id].present?
    subs << "credited to #{credit.first_name}" if credit
    subs << "📝 #{payload[:note]}" if payload[:note].present?
    subs << "at #{Buddy::TimeParser.friendly(payload[:completed_at], user: nil)}" if payload[:completed_at].present?
    { title: title, sub: subs.join("\n").presence }
  },
  # Level 2: fires immediately as a pre-checked row; unchecking it destroys the
  # completion (which fires the :uncompleted trigger) via the revert descriptor.
  level:       2,
  execute:     ->(payload, ctx) {
    chore = Chore.find(payload[:chore_id])
    at = payload[:completed_at].present? ? (Time.zone.parse(payload[:completed_at].to_s) || Time.current) : Time.current
    credit = User.find_by(id: payload[:credit_user_id]) if payload[:credit_user_id].present?
    credit ||= ctx.user
    # Credit goes to them; `recorded_by` is what keeps the trigger reaching
    # whoever marked it too, or a personal chore marked done for a housemate
    # runs THEIR automations and none of the recorder's.
    recorded_by = (ctx.user if credit.id != ctx.user.id)
    result = ChoreCompleter.new(chore, credit, at: at, note: payload[:note], recorded_by: recorded_by).call
    if recorded_by
      # ChoreCompleter broadcasts against the credited person, and the Chores
      # channels are per-user - so the device that recorded this hears nothing
      # about it without a second one.
      related = (chore.parent_chore if chore.sub_chore?)
      ChoreBroadcaster.broadcast_changes!(ctx.user, chore, related: related)
    end
    out = { chore_completion_id: result.completion&.id, skipped_reason: result.skipped_reason }
    if result.completion&.id
      summary = "unmarked #{chore.name}#{" for #{credit.first_name}" if recorded_by}"
      out[:revert] = { op: "created", model: "ChoreCompletion", id: result.completion.id, summary: summary }
    end
    out
  },
  receipt:     ->(_result, ctx) {
    chore_id = ctx.proposal["payload"]&.dig("chore_id")
    at = ctx.proposal["payload"]&.dig("completed_at")
    credit = User.find_by(id: ctx.proposal["payload"]&.dig("credit_user_id"))
    name = Chore.find_by(id: chore_id)&.name || "that chore"
    who = credit && credit.id != ctx.user.id ? " for #{credit.first_name}" : ""
    suffix = at.present? ? " at #{Buddy::TimeParser.friendly(at, user: ctx.user)}" : ""
    "Marked #{name} done#{who}#{suffix} ✓"
  },
)
