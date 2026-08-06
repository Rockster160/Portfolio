Buddy::Tools.register(
  name:        :print_history,
  description: <<~TXT,
    Look up what's been on the 3D printer - file names, when each ran, how long
    it took, and whether it finished, failed, or is still going (with the time
    left on it). Use it whenever they ask about past prints ("what did I print
    yesterday", "how long did the phone holder take", "did that one finish").

    It is NOT how you start a print - that's `print_again`, and it goes first,
    because the printer is the authority on its own filenames and may hold ones
    that have never run before. Come here when `print_again` says it doesn't
    recognise the name: the printer knows a file by something nobody says out
    loud (`game_tray-vase`, `Wall_mount_phone_holder_v2`), and this is where you
    find out what that is so you can send it again. Never guess a file name; a
    wrong guess ties the machine up for hours.

    `query` matches on WORDS, in any order, however they're written - "game
    tray" finds `game_tray-vase`, and "phone holder" finds
    `Wall_mount_phone_holder_v2`. Pass what they called it and let the match
    sort it out; omit it for the recent ones. `days` bounds how far back
    (default 60).

    Results come straight back to you in this same turn - answer them with it
    right away rather than saying you'll go look.
  TXT
  # Reads ActionEvents, so it belongs to the same feature they do. Someone
  # without a printer simply has no print events, and the tool says so.
  feature:     :events,
  args:        {
    query: { type: :string,  required: false, description: "What they called it; words match in any order. Omit to list recent prints" },
    days:  { type: :integer, required: false, default: 60, description: "How many days back to look (1-730)" },
  },
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, _ctx) { { summary: "Check print history", resolved: {} } },
  label:       ->(_payload, _ctx) { "Print history" },
  execute:     ->(payload, ctx) {
    days  = (payload[:days] || Buddy::PrintHistory::DEFAULT_DAYS).to_i
    query = payload[:query].to_s.strip
    lines = Buddy::PrintHistory.call(user: ctx.user, query: query, days: days)

    # Only teach the reprint path when the function is really on their list —
    # print_again refuses outright without one, so pointing at it would just
    # burn a turn.
    howto = (
      if Buddy::PrintHistory.reprint_function(ctx.user)
        "To start one, call `print_again` with the exact name from the list. "
      else
        "They have no reprint function set up, so you can look but you can't start one. "
      end
    )

    {
      matched: query.presence,
      days:    days,
      prints:  lines,
      how:     (
        if lines.any?
          "Most recently printed first. The name at the front of each line is the printer's " \
            "own file name. Say what you found in your own words, short - don't read the list " \
            "back line by line. #{howto}If two could be the one they meant, ask which."
        else
          "Nothing matched over the last #{days} days. Tell them there's no print on record " \
            "for that and ask what it was called, or roughly when they ran it, so you can " \
            "look again. Don't start a print off a name you haven't seen here."
        end
      ),
    }.compact
  },
)
