Buddy::Tools.register(
  name:        :edit_chore_completion,
  description: <<~TXT,
    Change a chore completion that has ALREADY landed - its note, or the time it
    was done. This is the tool for "put 'Hint Raspberry' on those waters", "that
    one was actually at 3", "add a note to the one you just marked".

    A recorded completion is not frozen. Never tell them an already-marked chore
    can't be annotated or retimed - it can, and this does it.

    `chore` is a fuzzy chore name; `when` narrows which one. `recent` applies the
    same change to that many of the newest completions, which is what you want
    when several were marked at once - "both waters" is `recent: 2`, because a
    repeat completion writes one row per unit.

    Only pass what's changing. To REMOVE the completion instead, that's
    undo_chore_completion.
  TXT
  args:        {
    chore:  { type: :string,  required: true,  description: "Fuzzy chore name" },
    note:   { type: :string,  required: false, description: "New note, replacing whatever note is on it" },
    at:     { type: :string,  required: false, description: "Corrected completion time - past expression or ISO timestamp" },
    when:   { type: :string,  required: false, default: "last", description: "One of: today, yesterday, last" },
    recent: { type: :integer, required: false, default: 1, description: "How many of the newest completions to change" },
  },
  confirm:     ->(payload, ctx) {
    raise "nothing to change - pass a note or a time" if payload[:note].blank? && payload[:at].blank?

    wanted = payload[:recent].to_i.clamp(1, 10)
    rows   = ctx.resolve_chore_completions(payload[:chore], hint: (payload[:when] || "last").to_sym, limit: wanted)
    raise "no matching completion for #{payload[:chore].inspect}" if rows.empty?

    resolved = {
      completion_ids: rows.map(&:id),
      chore_id:       rows.first.chore_id,
      chore_name:     rows.first.chore.name,
    }
    if payload[:at].present?
      parsed = Buddy::TimeParser.parse_past(payload[:at], user: ctx.user)
      raise "couldn't parse time #{payload[:at].inspect}" if parsed.nil?

      resolved[:completed_at] = parsed.iso8601
    end

    # Report the count actually found: asking for two when only one exists is
    # common (they misremember how it was logged), and the row should say what
    # will really change rather than what was requested.
    subject = rows.one? ? "the #{resolved[:chore_name]} completion" : "#{rows.size} #{resolved[:chore_name]} completions"
    { summary: "Update #{subject}?", resolved: resolved }
  },
  label:       ->(payload, ctx) {
    count = Array(payload[:completion_ids]).size
    title = count > 1 ? "#{count}× #{payload[:chore_name]}" : payload[:chore_name].to_s

    diffs = []
    diffs << "📝 #{payload[:note]}" if payload[:note].present?
    diffs << "at #{Buddy::TimeParser.friendly(payload[:completed_at], user: ctx.user)}" if payload[:completed_at].present?
    { title: title, sub: diffs.join("\n").presence }
  },
  execute:     ->(payload, ctx) {
    rows = ChoreCompletion.where(id: Array(payload[:completion_ids]), user_id: ctx.user.id).to_a
    raise "those completions are gone now" if rows.empty?

    attrs = {}
    attrs[:note] = payload[:note].to_s if payload[:note].present?
    new_at = payload[:completed_at].present? ? Time.zone.parse(payload[:completed_at].to_s) : nil
    if new_at
      attrs[:completed_at] = new_at
      # Same rule the History page follows: the chore-day key is derived from
      # the timestamp, so moving a completion across the 4am boundary has to
      # move its day with it or streaks keep counting the old day.
      attrs[:day_key] = ChoreDay.current(ctx.user, at: new_at)
    end

    what    = attrs.key?(:note) ? "note" : "time"
    reverts = rows.map { |row|
      before = attrs.keys.index_with { |k| row.public_send(k) }
      row.update!(attrs)
      { op: "updated", model: "ChoreCompletion", id: row.id, before: before, summary: "put the old #{row.chore.name} #{what} back" }
    }

    chore = rows.first.chore
    ChoreStreak.rebuild_for!(ctx.user, chore) if attrs.key?(:day_key)
    ChoreBroadcaster.broadcast_changes!(ctx.user, chore, related: (chore.parent_chore if chore.sub_chore?))

    { chore_id: chore.id, chore_name: chore.name, changed: rows.size, reverts: reverts }
  },
  receipt:     ->(result, _ctx) {
    count = result[:changed].to_i
    what  = count > 1 ? "#{count} #{result[:chore_name]} completions" : "the #{result[:chore_name]} completion"
    "Updated #{what} ✓"
  },
)
