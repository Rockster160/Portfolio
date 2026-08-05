Buddy::Tools.register(
  name:        :search_agenda,
  description: <<~TXT,
    Look up something on the calendar BY NAME, anywhere in time. Your context
    only carries today plus the next eight days, so the moment they ask about
    anything outside that, this is the only way to know - and the eight days you
    can see will always contain SOMETHING that looks like a plausible answer,
    which is exactly how a wrong one gets said with confidence.

    Use it for "when is my next 1-1 with Eric", "when's the dentist again",
    "do I have anything with Andrew coming up", "when did I last do a plunge",
    "is that thing still on the calendar". Use it too before telling anyone a
    thing ISN'T scheduled - not seeing it in your eight-day window is not
    evidence it doesn't exist.

    `query` is a name fragment ("eric", "dentist", "plunge") - match on how they
    said it, not the full title. `direction` is `upcoming` for "next" (the
    default), `past` for "last time", `any` when they just want to know whether
    it exists at all. `days` bounds how far to reach, default 180.

    It comes BACK to you with the matches and their ids, so you can answer, or
    act with `edit_agenda_item`, in your NEXT reply. In THIS one give only a
    short lead-in ("let me look"). If it finds nothing, say so plainly - a
    calendar with nothing on it is a real answer and much better than a guess.
  TXT
  feature:     :agenda,
  args:        {
    query:     { type: :string, required: true, description: "Name fragment to match, in their words" },
    direction: {
      type:        :enum,
      required:    false,
      default:     :upcoming,
      values:      Buddy::AgendaSearch::DIRECTIONS,
      description: "Which way to look from now",
    },
    days:      { type: :integer, required: false, default: 180, description: "How far to reach in days (1-1095)" },
  },
  # Level 1 (auto): a read that relays its own follow-up turn, same shape as
  # search_events. Nothing changes, so there's nothing to confirm.
  auto:        true,
  confirm:     ->(_payload, _ctx) { { summary: "Search the calendar", resolved: {} } },
  label:       ->(_payload, _ctx) { "Search calendar" },
  execute:     ->(payload, ctx) {
    query     = payload[:query].to_s.strip
    direction = (payload[:direction].presence || :upcoming).to_sym
    days      = (payload[:days] || Buddy::AgendaSearch::DEFAULT_DAYS).to_i
    found     = Buddy::AgendaSearch.call(user: ctx.user, query: query, direction: direction, days: days)
    rows      = Buddy::AgendaSearch.rows(found[:items], ctx.user, found[:sources])

    relayed = !ctx.conversation.nil?
    if relayed
      facing = { past: "before now", any: "either side of now" }.fetch(direction, "from now on")
      body = (
        if rows.any?
          more = found[:total] > rows.length ? " (showing #{rows.length} of #{found[:total]})" : ""
          "You searched their calendar for `#{query}` #{facing} and found, nearest first#{more}:\n" \
            "#{rows.join("\n")}\n\n" \
            "Answer them from THIS, not from what you remember being on the calendar. Give the one " \
            "they asked about in your own words, with the day and time; don't read the list back. " \
            "An entry marked as somebody else's is on a shared calendar and is not theirs to do. " \
            "To change one, call `edit_agenda_item` with its id. Don't search again this turn."
        else
          "You searched their calendar for `#{query}` #{facing}, across #{days} days, and found " \
            "NOTHING. Tell them plainly that there's nothing on the calendar for it - that is the " \
            "real answer and they need it. Do not offer a nearby item as though it might be the one, " \
            "and do not guess at a day. Offer to put it on if they want."
        end
      )
      Buddy::CompanionDelivery.deliver_prompt(
        user:         ctx.user,
        conversation: ctx.conversation,
        seed:         body,
        metadata:     { "kind" => "buddy_trigger", "hidden" => true, "source" => "agenda_search" },
      )
    end
    { relayed: relayed, count: rows.size, total: found[:total] }
  },
  receipt:     ->(result, _ctx) {
    next nil if result[:relayed]

    "Couldn't search your calendar right now."
  },
)
