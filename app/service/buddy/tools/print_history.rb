Buddy::Tools.register(
  name:        :print_history,
  description: <<~TXT,
    Look up what's been on the 3D printer - file names, when each ran, how long
    it took, and whether it finished, failed, or is still going (with the time
    left on it). Use it whenever they ask about past prints ("what did I print
    yesterday", "how long did the phone holder take", "did that one finish").

    Use it FIRST when they want something printed again but described it
    instead of naming it - "print that phone thing from earlier again". The
    name it comes back with is what the printer knows the file by, and that
    name is what the reprint function on your Jil list takes. Never guess a
    file name or start a print from memory; a wrong guess ties the machine up
    for hours.

    `query` narrows to prints whose name contains it, so pass the word they
    used ("phone", "vase"); omit it for the recent ones. `days` bounds how far
    back (default 60).

    It runs on its own and the results land in your NEXT reply - in THIS one
    just give a short lead-in ("let me check what you've run lately").
  TXT
  # Reads ActionEvents, so it belongs to the same feature they do. Someone
  # without a printer simply has no print events, and the tool says so.
  feature:     :events,
  args:        {
    query: { type: :string,  required: false, description: "Name fragment to match; omit to list recent prints" },
    days:  { type: :integer, required: false, default: 60, description: "How many days back to look (1-730)" },
  },
  # Level 1 (auto): a read that relays its own follow-up turn, same as
  # search_events. Nothing here changes anything, so there's nothing to confirm.
  auto:        true,
  confirm:     ->(_payload, _ctx) { { summary: "Check print history", resolved: {} } },
  label:       ->(_payload, _ctx) { "Print history" },
  execute:     ->(payload, ctx) {
    days  = (payload[:days] || Buddy::PrintHistory::DEFAULT_DAYS).to_i
    query = payload[:query].to_s.strip
    lines = Buddy::PrintHistory.call(user: ctx.user, query: query, days: days)

    relayed = !ctx.conversation.nil?
    if relayed
      subject = query.present? ? " matching `#{query}`" : ""
      reprint = Buddy::PrintHistory.reprint_function(ctx.user)
      # Only teach the reprint path when the function is really on their list —
      # `call_jil_function` refuses a name it can't match, so naming one that
      # isn't there would just burn a turn.
      howto = (
        if reprint
          "If they want one started again, call `call_jil_function` with " \
            "name=\"#{reprint.name}\" and args={\"file\": \"<the exact name from the list>\"}. " \
            "Leave `file` out only when they mean the very last print. "
        else
          ""
        end
      )
      body = (
        if lines.any?
          "You looked up their 3D print history#{subject}. Most recently printed first:\n" \
            "#{lines.join("\n")}\n\n" \
            "Tell them what you found in your own words, short - don't read the list back " \
            "line by line. The name at the front of each line is the printer's own file name. " \
            "#{howto}If two could be the one they meant, ask which. Don't look again this turn."
        else
          "You looked up their 3D print history#{subject} over the last #{days} days and found " \
            "nothing. Tell them there's no print on record for that, and ask what it was called " \
            "or roughly when they ran it so you can look again."
        end
      )
      Buddy::CompanionDelivery.deliver_prompt(
        user:         ctx.user,
        conversation: ctx.conversation,
        seed:         body,
        metadata:     { "kind" => "buddy_trigger", "hidden" => true, "source" => "print_history" },
      )
    end
    { relayed: relayed, count: lines.size }
  },
  receipt:     ->(result, _ctx) {
    next nil if result[:relayed]

    "Couldn't pull up your print history right now."
  },
)
