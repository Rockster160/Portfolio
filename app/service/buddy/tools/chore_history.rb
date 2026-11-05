Buddy::Tools.register(
  name:        :chore_history,
  summary:     "Who did a chore, and when, over recent days - \"who fed Whisper this week\", " \
               "\"when did we last change the litter\", a count per person.",
  description: <<~TXT,
    Look up the completions of ONE chore over recent days: each time it was
    done, when, and who it was credited to, plus a count per person. Use for
    "who fed Whisper the last 5 days", "chart who's done the dishes this week",
    "when did the litter last get changed", "how many times did Chelsea walk
    the dog". It covers the whole household, not only the person asking.

    `chore` is a fuzzy chore name. `days` = how far back (default 7, up to 90).

    The rows come straight back to you in this same turn, so answer from them
    right away. "Someone outside the house" is a completion nobody in the
    household is credited with.
  TXT
  feature:     :chores,
  args:        {
    chore: { type: :string,  required: true,  description: "Fuzzy name of the chore" },
    days:  { type: :integer, required: false, default: 7, description: "How many days back to include (1-90)" },
  },
  auto:        true,
  answers:     true,
  confirm:     ->(payload, ctx) {
    chore = ctx.resolve_chore(payload[:chore])
    ctx.no_chore!(payload[:chore]) if chore.nil?

    { summary: "#{chore.name} history", resolved: { chore_id: chore.id } }
  },
  label:       ->(_payload, _ctx) { "Chore history" },
  execute:     ->(payload, ctx) {
    chore   = Chore.find(payload[:chore_id])
    days    = (payload[:days] || 7).to_i.clamp(1, 90)
    zone    = ctx.user.timezone
    members = ctx.user.chore_household&.member_user_ids || [ctx.user.id]

    # A sub-chore's tap is the parent done too, so both count.
    scope = ChoreCompletion.where(user_id: members, occurrence_skipped: false)
    scope = scope.where(chore_id: chore.id).or(scope.where(parent_chore_id: chore.id))
    scope = scope.where(completed_at: (days - 1).days.ago.in_time_zone(zone).beginning_of_day..)
    rows  = scope.includes(:user).order(completed_at: :desc).to_a

    who   = ->(row) { row.anonymous? ? "someone outside the house" : row.user.first_name }
    lines = rows.map { |row|
      at = row.completed_at.in_time_zone(zone)
      "#{at.strftime("%a %-m/%-d")} #{Buddy::Clock.at(at, zone: zone)} · #{who.call(row)}"
    }

    {
      chore:  chore.name,
      days:   days,
      total:  rows.size,
      counts: rows.group_by(&who).transform_values(&:size),
      done:   lines,
      how:    (
        if rows.any?
          "Newest first. Answer what they asked in your own words - the per-person counts " \
            "are already added up for you, so use them rather than counting the rows."
        else
          "Nobody did #{chore.name} in the last #{days} days. Say so plainly."
        end
      ),
    }
  },
)
