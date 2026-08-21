Buddy::Tools.register(
  name:        :track_delivery,
  description: <<~TXT,
    Put something on the delivery list by hand. Use when they mention a package
    nothing has emailed about yet - "I ordered a desk, should be here Friday",
    "the mattress is coming next week", "there's a package from my mum tomorrow".

    Most deliveries land on the list by themselves, off the shipping email, so
    this is for what won't: a shop that doesn't email them, an order placed on
    someone else's account, something a person told them about. Don't add a row
    for an Amazon order they just placed - that one will arrive on its own, and
    two rows for one package is worse than waiting.

    **A NEW row, only.** If the thing they're talking about is already on the
    list, whatever they're telling you about it is `update_delivery` - a moved
    date, a better name, and especially a tracking number, which usually
    arrives in a separate message hours after the package did. "Here's the
    tracking for the mattress" came back as a SECOND mattress: the number
    landed on a row nothing else knew about, and the one they were watching
    still had none. Check what's on the list before you add to it - and if it
    ISN'T there, add it in the same turn. Looking and then stopping ("that
    one's already on the way") is only an answer when it really is.

    `name` is what THEY call it ("computer desk"), not a catalogue title. `when`
    is the day it's expected; leave it off if they didn't say and it goes on
    today. `tracking` and `url` are optional and only worth passing if they gave
    you one.

    Pass `carrier` whenever they name one. A tracking number is only useful
    next to the company that issued it - the carrier is what turns the number
    into a tappable tracking link and what gets read back when they ask what's
    on the way. Leave it off when they didn't say; a row with no carrier is
    fine, a row with the wrong one is not.
  TXT
  feature:     :deliveries,
  args:        {
    name:     { type: :string, required: true,  description: "What they call it, in their words" },
    when:     { type: :string, required: false, description: "Day it's expected: \"today\", \"tomorrow\", \"friday\", \"N days/weeks\", or YYYY-MM-DD. Defaults to today" },
    tracking: { type: :string, required: false, description: "Tracking number, only if they gave one" },
    url:      { type: :string, required: false, description: "Order or tracking link, only if they gave one" },
    carrier:  { type: :enum, required: false, values: AmazonOrder::NAMED_CARRIERS, description: "Who's carrying it, only if they said - pass it alongside a tracking number" },
  },
  # Level 1: adding a row is low-stakes and the dashboard can edit or drop it,
  # so it goes on immediately with a receipt rather than asking first.
  auto:        true,
  confirm:     ->(payload, ctx) {
    raise "the delivery list isn't part of this person's setup" unless Buddy::Deliveries.available?(ctx.user)
    raise "a delivery needs a name" if payload[:name].to_s.strip.blank?

    # Resolved now, while there's still someone to ask: a day we can't read
    # would otherwise land the package silently on today. end_of_day_for rather
    # than resolve_time because this is a DAY — it takes "friday" and "next
    # week", which resolve_time (a raw clock parse) does not.
    said = payload[:when].to_s.strip
    on   = said.present? ? ctx.end_of_day_for(said)&.to_date : nil
    raise "couldn't read #{said.inspect} as a day" if said.present? && on.nil?

    { summary: "Track #{payload[:name].to_s.strip}", resolved: { on_iso: on&.iso8601 } }
  },
  label:       ->(payload, _ctx) { { title: payload[:name].to_s.truncate(60), sub: payload[:on_iso].presence } },
  execute:     ->(payload, ctx) {
    on = (Date.parse(payload[:on_iso].to_s) if payload[:on_iso].present?)
    order = Buddy::Deliveries.add!(
      user:     ctx.user,
      name:     payload[:name],
      on:       on,
      tracking: payload[:tracking],
      url:      payload[:url],
      carrier:  payload[:carrier],
    )
    { name: order.name, on: order.delivery_date }
  },
  # friendly_day is for a deadline and calls anything today-or-sooner "tonight",
  # which is the wrong word for a parcel. Deliveries phrase their own days.
  receipt:     ->(result, ctx) {
    due = (Date.parse(result[:on].to_s) rescue nil)
    when_str = (Buddy::Deliveries.friendly(due, ctx.user.perceived_today) if due)
    "Tracking **#{result[:name]}**#{" for #{when_str}" if when_str}"
  },
)
