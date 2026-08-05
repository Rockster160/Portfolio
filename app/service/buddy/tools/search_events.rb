Buddy::Tools.register(
  name:        :search_events,
  description: <<~TXT,
    Search the person's LOGGED events (ActionEvents) - the whole record, going
    back years, including what they logged elsewhere. `recent_events` in your
    context is only TODAY's handful, so an earlier day, a count, or a "when did
    I last..." comes from here, as does finding the one they want removed or
    changed.

    `query` takes the app's search syntax. Bare words match the NAME or the
    NOTES (`celsius`, `phone holder`). `name:coffee` contains it, `name::Coffee`
    is exactly it, and `notes:` works the same way. Dates COMPARE with no colon
    before the operator - `timestamp>2026-07-01`, `timestamp<2026-08-01` - while
    `timestamp:2026-08-05` means that whole day and `timestamp:2026-08` that
    whole month. `OR` between alternatives, `-` or `NOT` to exclude, parens to
    group, quotes around anything with a space; terms side by side are ANDed
    (`name::PrintFailed -notes:vase`). It's already scoped to this person, so
    there's no user filter and you never need one.

    `days` bounds how far back (default 14) - raise it, or put a `timestamp`
    bound in the query, for anything older.

    Matches come BACK to you with their ids, so act in your NEXT reply:
    `delete_event` with that id to remove one, `edit_event` to change it. In
    THIS reply just give a short lead-in ("let me dig around for that"). If
    several could match, ask which. Don't search twice in one turn.
  TXT
  feature:     :events,
  args:        {
    query: { type: :string,  required: false, description: "Search syntax or plain words; omit to list recent" },
    days:  { type: :integer, required: false, default: 14, description: "How many days back to search (1-730)" },
  },
  # Level 1 (auto): a read that feeds its results back into a fresh Buddy turn
  # (like check_weather), so Buddy can find the right event and then act on it.
  auto:        true,
  confirm:     ->(_payload, _ctx) { { summary: "Search events", resolved: {} } },
  label:       ->(_payload, _ctx) { "Search events" },
  execute:     ->(payload, ctx) {
    days   = (payload[:days] || Buddy::EventSearch::DEFAULT_DAYS).to_i.clamp(1, Buddy::EventSearch::MAX_DAYS)
    query  = payload[:query].to_s.strip
    found  = Buddy::EventSearch.call(user: ctx.user, query: query, days: days)
    rows   = Buddy::EventSearch.rows(found[:events], ctx.user)
    subject = query.present? ? " for `#{query}`" : ""

    relayed = !ctx.conversation.nil?
    if relayed
      # `total` vs what's shown matters for a counting question ("how many
      # coffees last month") — fifteen rows is the display cap, not the answer.
      more = found[:total] > rows.length ? " (showing #{rows.length} of #{found[:total]})" : ""
      body = (
        if rows.any?
          "You searched their logged events#{subject} and found, most recent first#{more}:\n" \
            "#{rows.join("\n")}\n\n" \
            "Tell them what you found, in your own words - don't recite the list back as rows. " \
            "If ONE clearly matches what they wanted done, act on it now: call `delete_event` " \
            "with that id to remove it, or `edit_event` with that id to change it. If several " \
            "could match, ask which. Don't search again this turn."
        else
          "You searched their logged events#{subject} over the last #{days} days and found " \
            "nothing. Tell them you couldn't find it, and ask for another detail (a different " \
            "word, roughly when) so you can look again."
        end
      )
      Buddy::CompanionDelivery.deliver_prompt(
        user:         ctx.user,
        conversation: ctx.conversation,
        seed:         body,
        metadata:     { "kind" => "buddy_trigger", "hidden" => true, "source" => "event_search" },
      )
    end
    { relayed: relayed, count: rows.size, total: found[:total] }
  },
  receipt:     ->(result, _ctx) {
    next nil if result[:relayed]

    "Couldn't search your events right now."
  },
)
