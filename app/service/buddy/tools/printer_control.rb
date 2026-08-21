Buddy::Tools.register(
  name:        :printer_control,
  description: <<~TXT,
    Warm the 3D printer up, cool it down, or send the head home. Nothing is
    printed and no file is chosen - this is the machine itself.

    Use it for "preheat the printer", "warm the printer up", "turn the printer
    on", "cool it down", "home the printer head".

    **This is not `print_again`.** That one puts a FILE on the bed and starts a
    job. They read alike and the consequence is not alike: asked to "preheat
    printer", a companion called `print_again` with no `file`, which means "the
    last thing printed", and started a 40-minute vase that had to be cancelled
    at the machine. A printer verb that isn't about a file is this tool. If
    neither fits, say what you can't do rather than reaching for the one that
    starts hardware.

    `action` is one of `preheat`, `cool`, `home`.
  TXT
  feature:     :jil,
  args:        {
    action: {
      type:        :enum,
      required:    true,
      values:      %i[preheat cool home],
      description: "preheat to warm it up, cool to bring it down, home to send the head home",
    },
  },
  # Level 2: it changes something physical, so it lands as a row that's already
  # ticked and can be unticked - not the silent level-1 path `print_again` uses.
  # Warming a printer nobody meant to warm costs power and a wait; starting a
  # print costs hours and a spool, which is why that one is louder still.
  confirm:     ->(payload, _ctx) {
    { summary: "#{payload[:action].to_s.titleize} the printer", resolved: {} }
  },
  label:       ->(payload, _ctx) {
    { title: { preheat: "Preheat printer", cool: "Cool printer", home: "Home printer head" }[payload[:action].to_sym] }
  },
  # A routine step on purpose: "turn the printer on, wait a minute, then preheat
  # it" is the worked example the wait machinery was built for.
  routinable:  true,
  execute:     ->(payload, _ctx) {
    said = PrinterCommand.command(payload[:action].to_s)
    { action: payload[:action], printer_said: said }
  },
  receipt:     ->(result, _ctx) { result[:printer_said].presence || "Printer: #{result[:action]}" },
)
