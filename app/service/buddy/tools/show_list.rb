Buddy::Tools.register(
  name:        :show_list,
  description: <<~TXT,
    Put one of their lists in front of them as tickable boxes - one box per
    item, and ticking it checks that item off exactly the way ticking it in the
    app does. Use whenever they ask to SEE a list: "show me the grocery list",
    "what's on TODO", "read me my shopping list", "what's left on Before Bed".

    THIS CALL IS THE ANSWER, and it is the only thing that draws the boxes. Say
    something short in your own words and let the rows do the rest - reciting
    the items in prose above them prints the list twice, and writing the
    lead-in WITHOUT calling this leaves them looking at an introduction to
    nothing.

    `list` is a fuzzy name and matches against the lists they have.

    A long list is capped, and the card says how many didn't fit. Don't
    apologize for that or offer to read the rest out - the app is where a long
    list gets read.

    Adding, removing or editing an item is still its own tool. This only shows.
  TXT
  feature:     :lists,
  args:        {
    list: { type: :string, required: true, description: "Fuzzy list name" },
  },
  # Level 1 (auto) and NOT an `answers:` tool, same as `list_reminders`: what it
  # produces is for the PERSON, drawn in the thread, rather than findings handed
  # back to the model. So it runs after the reply, on the execute path.
  auto:        true,
  confirm:     ->(payload, ctx) {
    list = ctx.resolve_list(payload[:list])
    raise "no list matching #{payload[:list].inspect}" if list.nil?

    { summary: "Show #{list.name}", resolved: { list_id: list.id } }
  },
  label:       ->(payload, _ctx) { "Show #{List.find_by(id: payload[:list_id])&.name || payload[:list]}" },
  execute:     ->(payload, ctx) {
    list = List.find_by(id: payload[:list_id])
    next { shown: 0 } if list.nil?

    # The list's own name is the card's heading. A canned lead-in ("here's your
    # list!") would be the same sentence under every list forever, and the model
    # has already written the words above it in its own voice.
    shown = Buddy::ListChecklist.post!(user: ctx.user, list: list, text: list.name)
    { shown: shown, list_name: list.name }
  },
  # The card IS the output, so nothing on top of it when it went up. An EMPTY
  # list posts no card at all, and that is the one case where the person is left
  # with nothing to look at unless this says so.
  receipt:     ->(result, _ctx) {
    next nil if result[:shown].to_i.positive?

    "Nothing on #{result[:list_name] || "that list"} right now."
  },
)
