Buddy::Tools.register(
  name:        :describe_screen,
  description: <<~TXT,
    Read what is actually on their screen, so you can tell them where a control
    is and what it does. Call it whenever somebody asks HOW to do something in
    the app, what a button is, where a setting lives, or how to stop / change /
    find something they can see - "how do I turn these notifications off",
    "what's the bell for", "where do I change the text size", "how do I get rid
    of a reminder".

    THE ANSWER IS NOT THIS CALL. It hands you the list; you still have to read
    it and say the one thing they asked about, in your own words, in a sentence
    or two. Don't recite the whole screen at somebody who asked about one
    button.

    **Never name a control that isn't in what comes back.** This is the whole
    reason the tool exists: an invented tab sends somebody hunting the screen
    for something that has never been there. If what they want isn't here, say
    so plainly - that is a real answer - and offer `request_feature`.

    Two things it does NOT cover, and both have their own answer:
    - Something you can just DO for them. Asked to make the text bigger, use
      `set_font_size`; asked what is on the agenda, read it out. A tour is the
      worse answer whenever a tool can do the thing.
    - The other PAGES of the app, which are links rather than controls.
  TXT
  args:        {},
  answers:     true,
  auto:        true,
  confirm:     ->(_payload, _ctx) { { summary: "Read the screen", resolved: {} } },
  label:       ->(_payload, _ctx) { "Read the screen" },
  execute:     ->(_payload, ctx) {
    { areas: Buddy::ScreenGuide.for_user(ctx.user) }
  },
  # No chip: this is reading, and what the person sees is the sentence it
  # produced rather than the fact that it was looked up.
  receipt:     ->(_result, _ctx) {},
)
