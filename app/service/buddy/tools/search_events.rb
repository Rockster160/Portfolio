Buddy::Tools.register(
  name:        :search_events,
  description: <<~TXT,
    Search the person's LOGGED events (ActionEvents) to find a specific one -
    including events they logged elsewhere, not just through you. Use when they
    ask to remove / edit / ask about something they logged and you don't already
    have the exact match in `recent_events`. Run a couple of scoped searches if
    the first doesn't land it.

    `query` is a name fragment ("celsius", "coffee"); omit to just list the
    latest. `days` limits how far back (default 14). It fetches the matches and
    comes BACK to you with their ids so you can act (e.g. remove the right one).
    In THIS reply just give a short lead-in ("let me dig around for that") - the
    results land in your NEXT reply.
  TXT
  feature:     :events,
  args:        {
    query: { type: :string,  required: false, description: "Name fragment to match; omit to list recent" },
    days:  { type: :integer, required: false, default: 14, description: "How many days back to search (1-90)" },
  },
  # Level 1 (auto): a read that feeds its results back into a fresh Buddy turn
  # (like check_weather), so Buddy can find the right event and then act on it.
  auto:        true,
  confirm:     ->(_payload, _ctx) { { summary: "Search events", resolved: {} } },
  label:       ->(_payload, _ctx) { "Search events" },
  execute:     ->(payload, ctx) {
    days  = (payload[:days] || 14).to_i.clamp(1, 90)
    query = payload[:query].to_s.strip

    scope = ctx.user.action_events.where(timestamp: days.days.ago..)
    scope = scope.where("LOWER(name) LIKE ?", "%#{query.downcase}%") if query.present?
    rows = scope.order(timestamp: :desc).limit(15).map { |e|
      when_str = e.timestamp.in_time_zone(ctx.user.timezone).strftime("%a %-m/%-d %-I:%M%P").sub(":00", "")
      notes = e.notes.to_s.strip
      "##{e.id} · #{e.name}#{" (#{notes.truncate(40)})" if notes.present?} · #{when_str}"
    }

    relayed = !ctx.conversation.nil?
    if relayed
      body = if rows.any?
        "You searched their logged events#{" for \"#{query}\"" if query.present?} and found (most recent first):\n#{rows.join("\n")}\n\nTell them what you found, in your own words. If ONE clearly matches what they want, act on it - to remove it emit [[propose: delete_event id=<the id>]], to change it emit [[propose: edit_event id=<the id> ...]]. If several could match, ask which. Don't search again this turn."
      else
        "You searched their logged events#{" for \"#{query}\"" if query.present?} over the last #{days} days and found nothing. Tell them you couldn't find it, and ask for another detail (a different word, roughly when) so you can look again."
      end
      Buddy::CompanionDelivery.deliver_prompt(
        user:         ctx.user,
        conversation: ctx.conversation,
        seed:         body,
        metadata:     { "kind" => "buddy_trigger", "hidden" => true, "source" => "event_search" },
      )
    end
    { relayed: relayed, count: rows.size }
  },
  receipt:     ->(result, _ctx) {
    next nil if result[:relayed]

    "Couldn't search your events right now."
  },
)
