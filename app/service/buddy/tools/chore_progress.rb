Buddy::Tools.register(
  name:        :chore_progress,
  description: <<~TXT,
    Look up how the person did on their DAILY chores over recent days, then tell
    them. Use when they ask "did I get everything done yesterday", "how'd my
    dailies go this week", "am I keeping up with my goals", "how many days did I
    hit everything". This is a LOOKUP - don't guess from memory.

    `days` = how many days back to include (default 7; 1 = just today). The
    per-day progress comes straight back to you in this same turn, so tell them
    right away rather than saying you'll go check - warmly, celebrating the full
    days and kind about the misses, never as a table.
  TXT
  feature:     :chores,
  args:        {
    days: { type: :integer, required: false, default: 7, description: "How many days back to include (1-31)" },
  },
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, _ctx) { { summary: "Chore progress", resolved: {} } },
  label:       ->(_payload, _ctx) { "Chore progress" },
  execute:     ->(payload, ctx) {
    days = (payload[:days] || 7).to_i
    rows = Buddy::ChoreHistory.progress(ctx.user, days: days)
    lines = rows.map { |r|
      status = r[:missed].empty? ? "all #{r[:total]} done ✅" : "#{r[:done]}/#{r[:total]} (missed: #{r[:missed].join(", ")})"
      "#{r[:date].strftime("%a %-m/%-d")}: #{status}"
    }

    {
      days:     days,
      progress: lines,
      how:      (
        if lines.any?
          "Tell them warmly in your own words - celebrate the days they nailed everything, be " \
            "encouraging (never scolding) about any misses, and don't recite the raw table. " \
            "Today's row is still in progress, so frame it that way."
        else
          "Nothing on record over those #{days} days. Say so plainly rather than inventing a streak."
        end
      ),
    }
  },
)
