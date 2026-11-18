Buddy::Tools.register(
  name:        :generate_image,
  summary:     "Draw a new picture from a description and post it in the thread: \"make me an " \
               "image of a blue rose\", \"draw a cat in a spacesuit\".",
  description: <<~TXT,
    Make a brand new picture from a description and put it in this
    conversation. Use it whenever they ask you to draw, make, create, generate
    or paint an image, picture, drawing, illustration, wallpaper or icon of
    something.

    `prompt` is what the image model reads, so write it out in full: the
    subject, the setting, the style (photo, watercolour, cartoon, line art),
    the colours, the mood. Fill in what they left open with something good
    rather than asking. A follow-up like "make it purple" or "now at night" is
    a new picture: write the whole prompt again with the change in it.

    `shape` is square unless they want it tall (a phone wallpaper, a poster) or
    wide (a desktop wallpaper, a banner).

    `caption` is a few words naming the picture, shown with it.

    It takes a little while and the picture lands just above your reply, so
    say something about it in a line rather than describing it: you haven't
    seen it.
  TXT
  args:        {
    prompt:  { type: :string, required: true, description: "The full description the image model draws from" },
    shape:   { type: :enum, required: false, values: %i[square portrait landscape], description: "Square, tall or wide" },
    caption: { type: :string, required: false, description: "A few words naming the picture" },
  },
  # No `feature:` - any thread can ask for a picture.
  auto:        true,
  answers:     true,
  acts:        true,
  # The picture is made when it's asked for. A routine making one on a schedule
  # spends money on something nobody is looking at.
  routinable:  false,
  confirm:     ->(payload, _ctx) {
    prompt = payload[:prompt].to_s.strip
    raise "no description of what to draw" if prompt.blank?

    caption = payload[:caption].to_s.strip.presence || prompt.truncate(60)
    {
      summary:  "Draw #{caption}",
      resolved: { prompt: prompt, shape: payload[:shape].presence || :square, caption: caption },
    }
  },
  label:       ->(payload, _ctx) { "🎨 #{payload[:caption]}" },
  execute:     ->(payload, ctx) {
    begin
      png = Buddy::ImageGenerator.call(
        user:         ctx.user,
        prompt:       payload[:prompt],
        shape:        payload[:shape],
        conversation: ctx.conversation,
      )
    rescue Buddy::ImageGenerator::Error => e
      next {
        drawn: nil,
        error: e.message,
        how:   "Nothing was drawn and nothing was posted. Tell them plainly why, and if the model " \
               "refused, offer to try a differently worded version.",
      }
    end

    message = Buddy::ImageGenerator.post!(
      conversation: ctx.conversation || ByteConversation.default_for(ctx.user),
      user:         ctx.user,
      png:          png,
      prompt:       payload[:prompt],
      caption:      payload[:caption],
    )

    {
      drawn:      payload[:caption],
      message_id: message.id,
      how:        "The picture is in the thread now, just above your reply - they can see it. Say " \
                  "something about it in a line. Don't describe it: you haven't looked at it.",
    }
  },
)
