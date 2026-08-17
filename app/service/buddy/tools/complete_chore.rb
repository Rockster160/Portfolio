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

    To change a completion that's already recorded — attach the note you
    missed, correct the time — use `edit_chore_completion`, not a second
    `complete_chore`.
  TXT
  feature:     :chores,
  args:        {
    chore: { type: :string, required: true,  description: "Fuzzy chore name" },
    note:  { type: :string, required: false, description: "Optional note captured on the completion" },
    at:    { type: :string, required: false, description: "When it was actually done - past time expression or ISO timestamp. Omit for 'now'." },
  },
  confirm:     ->(payload, ctx) {
    chore = ctx.resolve_chore(payload[:chore])
    raise ctx.no_chore_error(payload[:chore]) if chore.nil?

    # A fuzzy name lands on the container when a chore has been split per
    # person ("Teeth" holding one Teeth each), and a completion on the
    # container ticks nobody's card. Down one level HERE, so the id every stage
    # after this one reads - label, merge key, execute, receipt, undo - is the
    # chore that actually gets the row.
    chore = chore.completion_leaf_for(ctx.user)
    resolved = { chore_id: chore.id }
    if payload[:at].present?
      parsed = Buddy::TimeParser.parse_past(payload[:at], user: ctx.user)
      raise "couldn't parse time #{payload[:at].inspect}" if parsed.nil?

      resolved[:completed_at] = parsed.iso8601
    end

    when_str = resolved[:completed_at] ? " (at #{Buddy::TimeParser.friendly(resolved[:completed_at], user: ctx.user)})" : ""
    { summary: "Mark #{chore.name} done#{when_str}?", resolved: resolved }
  },
  label:       ->(payload, ctx) {
    chore = Chore.find_by(id: payload[:chore_id])
    title = chore&.name || payload[:chore].to_s

    subs = []
    if chore&.assigned? && chore.assigned_to_user_id != ctx.user.id
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
  # that differ only in count still merge, ones that differ in note don't.
  merge_key:   ->(payload) { "complete_chore:#{payload[:chore_id]}:#{payload[:completed_at]}:#{payload[:note]}" },
  merge_label: ->(payload, count) {
    chore = Chore.find_by(id: payload[:chore_id])
    title = "#{count}× #{chore&.name || payload[:chore]}"
    subs = []
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
    result = ChoreCompleter.new(chore, ctx.user, at: at, note: payload[:note]).call
    out = { chore_completion_id: result.completion&.id, skipped_reason: result.skipped_reason }
    if result.completion&.id
      out[:revert] = { op: "created", model: "ChoreCompletion", id: result.completion.id, summary: "unmarked #{chore.name}" }
    end
    out
  },
  receipt:     ->(_result, ctx) {
    chore_id = ctx.proposal["payload"]&.dig("chore_id")
    at = ctx.proposal["payload"]&.dig("completed_at")
    name = Chore.find_by(id: chore_id)&.name || "that chore"
    suffix = at.present? ? " at #{Buddy::TimeParser.friendly(at, user: ctx.user)}" : ""
    "Marked #{name} done#{suffix} ✓"
  },
)
