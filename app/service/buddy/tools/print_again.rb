Buddy::Tools.register(
  name:        :print_again,
  description: <<~TXT,
    Put a file back on the 3D printer. This is the tool for any "print that
    again" / "print another X" / "run the vase again" request.

    Send `file` as the person said it. The printer is the authority on its own
    filenames and it may well hold files that have never run before, so give it
    their words FIRST and let it answer. Omit `file` only when they mean the
    very last thing that printed.

    What the printer says comes straight back to you in this same turn:

    - It started - say so, using the name the printer used.
    - It didn't recognise the name - nothing started. Call `print_history` with
      the same words to find what the file is really called, then call this
      again with that exact name. Don't apologise your way out of it and don't
      ask them to spell it; looking it up is the whole point.

      **A miss there does NOT mean the file doesn't exist.** `print_history` is
      built from what has actually RUN, so a model the printer holds and has
      never printed is invisible to it - which is exactly the case that produces
      the miss you're recovering from. "tension para clip" came back with two
      unrelated files matched on the word `clip` alone, and the person typed
      "TensionParaClip" and it printed on the spot. Same characters. So when the
      history is thin or the matches look nothing like what they asked for, try
      the name with the spaces closed up before you go back to them, and if you
      do go back, ask which of the ones you found they meant rather than telling
      them it isn't there.
    - Anything else - relay what it actually said rather than deciding it worked.

    Never invent a filename to send. A wrong one either does nothing or ties the
    machine up for hours on the wrong model.

    **REPRINTS ONLY, and omitting `file` is not a way to handle a verb you
    don't recognise.** Warming the printer, cooling it, homing the head - those
    are `printer_control` and none of them touches a file. "Preheat printer"
    reached this tool with no `file`, which means "the last thing printed", and
    started a 40-minute vase that had to be cancelled at the machine. If what
    they asked for isn't a print, this is the wrong tool even when it's the
    closest one.
  TXT
  feature:     :jil,
  args:        {
    file: { type: :string, required: false, description: "Filename to print, in their words; omit for the last print" },
  },
  auto:        true,
  # Acts AND reports: the model has to see a refusal in time to go find the real
  # name, which is the whole reason this doesn't run after the reply like every
  # other level-1 tool.
  answers:     true,
  acts:        true,
  # Not a routine step. Omitting `file` means "the last print", which is a
  # different file every time, and naming one pins a routine to a model they
  # printed once.
  routinable:  false,
  confirm:     ->(_payload, ctx) {
    raise "there's no reprint function set up for the printer" if Buddy::PrintHistory.reprint_function(ctx.user).nil?

    { summary: "Send it to the printer", resolved: {} }
  },
  label:       ->(payload, _ctx) { { title: "Print again", sub: payload[:file].presence } },
  execute:     ->(payload, ctx) {
    result = Buddy::Reprint.call(user: ctx.user, file: payload[:file])
    asked  = result[:file] || "the last print"
    # The printer names the file it actually matched, so a print started from
    # "game tray" reports as `game_tray-vase` without a second lookup.
    started = result[:printed] || asked

    missed = result[:outcome] == :missed
    # The chip is the durable trace, and a refusal earns one as much as a start
    # does — two chips on a retry is the honest record of what happened.
    if ctx.conversation
      Buddy::ActivityChip.post!(
        conversation: ctx.conversation,
        user:         ctx.user,
        tool_name:    :print_again,
        ok:           !missed,
        body:         missed ? "Printer didn't know **#{asked}**" : "Sent **#{started}** to the printer",
        detail:       result[:printer_said],
        payload:      { file: result[:printed] || result[:file] }.compact,
      )
    end

    {
      sent:         asked,
      printing:     result[:printed],
      outcome:      result[:outcome],
      printer_said: result[:printer_said],
      how:          (
        case result[:outcome]
        when :missed
          "The printer does not have a file by that name and NOTHING is printing. Call " \
          "`print_history` with the same words to find what it's really called, then call " \
          "`print_again` with that exact name. Only tell them you couldn't find it once " \
          "that lookup has also come back empty."
        when :started
          "It's printing. Say so briefly, using the name under `printing` - that's what the " \
          "printer matched, and it may not be the words they used."
        else
          "The printer answered with something neither of us can read as started or refused, " \
          "so you can't tell whether it took. Say exactly that, quoting what it said - don't " \
          "call it printing and don't send it again on your own."
        end
      ),
    }.compact
  },
  # Deliberate opt-out — `execute` files its own chip (and files one for a
  # refusal too). Same reason as call_jil_function: a receipt here would double
  # up under it whenever a routine runs this.
  receipt:     ->(_result, _ctx) {},
)
