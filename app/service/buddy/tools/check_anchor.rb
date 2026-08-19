Buddy::Tools.register(
  name:        :check_anchor,
  description: <<~TXT,
    Look up when a named recurring moment happens next - sunset, sunrise, trash
    pickup, or anything else they've set up as an "anchor". Use when they ask
    when one of these is ("when's sunset?", "when do the bins go out?", "how
    long until sunrise?"), or when you need the time to answer something else
    ("do I have time for a walk before dark?").

    `key` is the anchor's name and looks like `domain:event` - `sun:sunset`,
    `trash:pickup`. Omit it to get every anchor's next time at once, which is
    also how you find out which ones exist. Don't guess at a key you haven't
    seen; call it with no key first and use what comes back.

    `offset` is optional and shifts the answer - "-30m" for half an hour before,
    "+1h" for an hour after. Handy for "when should I leave to catch sunset".

    The reading comes straight back to you in this same turn, so answer right
    away rather than saying you'll go check. These are real times, not
    estimates - don't round them into vagueness if they asked for the actual
    time, and don't invent one for an anchor that comes back empty.
  TXT
  args:        {
    key:    {
      type:        :string,
      required:    false,
      description: "Anchor name like sun:sunset; omit to list them all",
    },
    offset: {
      type:        :string,
      required:    false,
      description: "Shift the answer, e.g. -30m, +1h30m, -1w",
    },
  },
  auto:        true,
  answers:     true,
  confirm:     ->(payload, _ctx) {
    key = payload[:key] || payload["key"]
    { summary: key.present? ? "Next #{key}" : "Upcoming anchors", resolved: {} }
  },
  label:       ->(payload, _ctx) { "Anchor · #{payload[:key] || payload["key"] || "all"}" },
  execute:     ->(payload, ctx) {
    key    = (payload[:key] || payload["key"]).to_s.strip
    offset = (payload[:offset] || payload["offset"]).to_s.strip
    zone   = ActiveSupport::TimeZone[ctx.user.timezone] || Time.zone

    reading = ->(anchor) {
      at = Anchor.resolve("#{anchor.key}#{offset}", user: ctx.user)
      { anchor: anchor.key, next: at&.in_time_zone(zone)&.strftime("%A %-d %B, %-I:%M%P") }
    }

    if key.present?
      anchor = Anchor.for(ctx.user, AnchorExpression.key_in(key) || key)
      raise "there's no anchor called #{key}" if anchor.nil?

      found = reading.call(anchor)
      raise "#{anchor.key} has no upcoming time on it" if found[:next].nil?

      next found.merge(
        how: "Tell them in your own words. It's a real time - keep it exact if " \
             "they asked for the time itself.",
      )
    end

    anchors = ctx.user.anchors.order(:key).to_a
    raise "they haven't set up any anchors yet" if anchors.empty?

    {
      anchors: anchors.map { |anchor| reading.call(anchor) },
      how:     "These are the recurring moments they've set up. Mention the ones " \
               "that bear on what they asked, not the whole list.",
    }
  },
)
