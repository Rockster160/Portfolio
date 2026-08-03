Buddy::Tools.register(
  name:        :set_font_size,
  description: <<~TXT,
    Change how big the text in this chat renders for them. Use it when they
    say the text is too small or too hard to read, ask you to make it bigger,
    or want it back to normal - "bump the font", "that's too big", "can you
    make this easier to read", "put it back".

    `direction` is the usual shape: "bigger" or "smaller" nudges one step from
    wherever they are, "reset" returns to the default. Use `percent` only when
    they name a size outright ("set it to 150%").

    It applies immediately, everywhere they open Byte, and it sticks. The floor
    is 80 and the ceiling is 200; asking past either just lands on it, so say
    where it ended up rather than promising more.
  TXT
  args:        {
    direction: {
      type:        :enum,
      required:    false,
      values:      %i[bigger smaller reset],
      description: "Nudge one step, or go back to the default",
    },
    percent:   {
      type:        :integer,
      required:    false,
      description: "Exact size as a percentage of default (80-200). Only when they name a number.",
    },
  },
  # Level 1: a display preference is instant, visible the moment it lands, and
  # undone by saying "smaller". A checkbox for it would be a toll on the one
  # thing they can already see the result of.
  level:       1,
  confirm:     ->(payload, ctx) {
    current = ctx.user.byte_font_scale
    step    = User::FONT_SCALE_STEP

    wanted = if payload[:percent].present?
      payload[:percent].to_i
    else
      case payload[:direction].to_s
      when "bigger"  then current + step
      when "smaller" then current - step
      when "reset"   then 100
      else raise "say bigger, smaller, reset, or a percent"
      end
    end

    scale = wanted.clamp(User::FONT_SCALE_RANGE.min, User::FONT_SCALE_RANGE.max)
    # Already at the end of the range and asked for more. Worth its own answer:
    # "done" on a change that didn't happen is the reading they'd have to
    # discover by squinting at unchanged text.
    pinned = scale == current && wanted != current

    { summary: "Set the text size to #{scale}%?", resolved: { scale: scale, pinned: pinned } }
  },
  label:       ->(payload, _ctx) {
    { title: "Text size #{payload[:scale]}%", sub: nil }
  },
  execute:     ->(payload, ctx) {
    scale = payload[:scale].to_i
    ctx.user.update!(byte_font_scale: scale)
    # The page is already open, so push it rather than waiting for a reload.
    MonitorChannel.broadcast_to(ctx.user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :font_scale, scale: scale },
    })
    { scale: scale, pinned: payload[:pinned] }
  },
  receipt:     ->(result, _ctx) {
    return "Text is already as #{result[:scale] >= User::FONT_SCALE_RANGE.max ? "big" : "small"} as it goes (#{result[:scale]}%)" if result[:pinned]

    "Text size → #{result[:scale]}%"
  },
)
