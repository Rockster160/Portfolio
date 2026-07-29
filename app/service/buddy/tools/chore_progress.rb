Buddy::Tools.register(
  name:        :chore_progress,
  description: <<~TXT,
    Look up how the person did on their DAILY chores over recent days, then tell
    them. Use when they ask "did I get everything done yesterday", "how'd my
    dailies go this week", "am I keeping up with my goals", "how many days did I
    hit everything". This is a LOOKUP - don't guess from memory.

    `days` = how many days back to include (default 7; 1 = just today). It fetches
    the per-day progress and comes BACK to you, so in THIS reply just a short
    lead-in ("let me check") - the actual summary lands in your NEXT reply, told
    warmly (celebrate the full days, be kind about the misses), not as a table.
  TXT
  args:        {
    days: { type: :integer, required: false, default: 7, description: "How many days back to include (1-31)" },
  },
  # Level 1 (auto): a read. Like check_weather, it feeds the result back into a
  # fresh Buddy turn so Buddy relays it in its own voice, not a raw chip - and it
  # is NOT preloaded into every turn's context.
  auto:        true,
  confirm:     ->(_payload, _ctx) { { summary: "Chore progress", resolved: {} } },
  label:       ->(_payload, _ctx) { "Chore progress" },
  execute:     ->(payload, ctx) {
    days = (payload[:days] || 7).to_i
    rows = Buddy::ChoreHistory.progress(ctx.user, days: days)

    relayed = rows.any? && !ctx.conversation.nil?
    if relayed
      lines = rows.map { |r|
        status = r[:missed].empty? ? "all #{r[:total]} done ✅" : "#{r[:done]}/#{r[:total]} (missed: #{r[:missed].join(", ")})"
        "#{r[:date].strftime("%a %-m/%-d")}: #{status}"
      }
      Buddy::CompanionDelivery.deliver_prompt(
        user:         ctx.user,
        conversation: ctx.conversation,
        seed:         "You just checked their daily-chore progress:\n#{lines.join("\n")}\n\nTell them warmly in your own words - celebrate the days they nailed everything, be encouraging (never scolding) about any misses, and don't recite the raw table. Today's row is still in progress, so frame it that way. Don't look it up again.",
        metadata:     { "kind" => "buddy_trigger", "hidden" => true, "source" => "chore_progress" },
      )
    end
    { relayed: relayed }
  },
  receipt:     ->(result, _ctx) {
    next nil if result[:relayed]

    "Couldn't pull your chore history right now."
  },
)
