Buddy::Tools.register(
  name:        :find_photo,
  description: <<~TXT,
    Find a picture they sent before, by what is IN it. Every photo gets a
    description written when it arrives, and this searches those. The results
    come straight back to you in this turn.

    Reach for it whenever they point at a picture that isn't in front of you:
    they ask what something looked like, what was in a shot, whether they ever
    sent one of a thing, or you need to check a photo before answering. Your
    prompt only shows images from the last few turns as
    `[image #1234: name.jpeg]` - past that a picture is not in your history at
    all, and this is the only way to reach it.

    `query` is what would be in the picture, in their words or yours: the
    object, the room, a brand, a colour, text on a label. Every word has to
    appear, so two or three is usually right and a sentence is too many.
    `since` and `until` narrow by when it was taken; `box` narrows to photos
    filed onto one inventory box.

    Each hit comes back with a `message_id` where there is one. That is what
    `view_image` takes, so when the description sounds like the one they mean
    and they want detail out of it, open it and answer from what you can
    actually see. The description is a finding aid, not a substitute for
    looking.
  TXT
  args:        {
    query: { type: :string, required: false, description: "What's in the picture - object, place, colour, label" },
    since: { type: :string, required: false, description: "Only photos taken on or after this (ISO date or datetime)" },
    until: { type: :string, required: false, description: "Only photos taken on or before this" },
    box:   { type: :string, required: false, description: "Only photos filed onto this inventory box key" },
  },
  # No `feature:` - a photo can arrive in any Buddy thread, so this belongs to
  # CORE the way `view_image` does.
  #
  # Level 1 + answers: a lookup settles inside the turn and hands the results
  # back, rather than leaving a checkbox asking permission to look.
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, _ctx) { { summary: "Look through their photos", resolved: {} } },
  label:       ->(_payload, _ctx) { "Look through their photos" },
  execute:     ->(payload, ctx) {
    found = Buddy::PhotoSearch.call(
      user:     ctx.user,
      query:    payload[:query],
      since:    Buddy::TimeParser.parse_past(payload[:since], user: ctx.user),
      until_at: Buddy::TimeParser.parse_past(payload[:until], user: ctx.user),
      box:      payload[:box],
    )
    photos = found[:photos]

    {
      query:   payload[:query].presence,
      total:   found[:total],
      showing: photos.length,
      photos:  Buddy::PhotoSearch.rows(photos),
      how:     (
        if photos.any?
          "Newest first. `what` is what was written down when the picture arrived, not what you can see " \
            "now. Say which one you mean in their terms rather than reading the description out, and if " \
            "they want anything the line doesn't already answer, call `view_image` with its `message_id` " \
            "and look."
        else
          "Nothing matched, and that IS the answer - say you can't find one rather than describing a " \
            "picture you haven't seen. Only photos sent since this started have descriptions, so an older " \
            "one may be in the thread without being findable here."
        end
      ),
    }.compact
  },
)
