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
  TXT
  args:        {
    chore: { type: :string, required: true,  description: "Fuzzy chore name" },
    note:  { type: :string, required: false, description: "Optional note captured on the completion" },
    at:    { type: :string, required: false, description: "When it was actually done - past time expression or ISO timestamp. Omit for 'now'." },
  },
  confirm:     ->(payload, ctx) {
    chore = ctx.resolve_chore(payload[:chore])
    raise "no chore matching #{payload[:chore].inspect}" if chore.nil?

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
    if payload[:completed_at].present?
      subs << "at #{Buddy::TimeParser.friendly(payload[:completed_at], user: ctx.user)}"
    end

    { title: title, sub: subs.join("\n").presence }
  },
  merge_key:   ->(payload) { "complete_chore:#{payload[:chore_id]}:#{payload[:completed_at]}" },
  merge_label: ->(payload, count) {
    chore = Chore.find_by(id: payload[:chore_id])
    title = "#{count}× #{chore&.name || payload[:chore]}"
    sub = payload[:completed_at].present? ? "at #{Buddy::TimeParser.friendly(payload[:completed_at], user: nil)}" : nil
    { title: title, sub: sub }
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
