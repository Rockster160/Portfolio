Buddy::Tools.register(
  name:        :delivery_arrived,
  description: <<~TXT,
    Mark something on the delivery list as turned up. Use when they say a
    package came - "the desk got here", "my light sockets arrived", "it came
    this morning".

    An Amazon package usually marks itself when the delivered email lands, so
    this matters most for the ones nothing emails about: a hand-added row, or
    one whose confirmation never came. Marking one that already says it arrived
    is harmless, so if they tell you it came, take their word over the list.

    `match` is a few words from the item's name. If two could be the one they
    meant, ask which rather than picking - the wrong one leaves a real package
    marked delivered and drops it out of the answer to "what's still coming".
  TXT
  feature:     :deliveries,
  args:        {
    match: { type: :string, required: true, description: "A few words from the item's name" },
  },
  auto:        true,
  confirm:     ->(payload, ctx) {
    raise "the delivery list isn't part of this person's setup" unless Buddy::Deliveries.available?(ctx.user)

    # Resolved here so a name matching nothing is refused while the model can
    # still say so, rather than being dropped under a reply claiming it's done.
    order = Buddy::Deliveries.find(ctx.user, payload[:match])
    raise "nothing on the delivery list matches #{payload[:match].to_s.strip.inspect}" if order.nil?

    { summary: "Mark #{order.name} as arrived", resolved: { name: order.name } }
  },
  label:       ->(payload, _ctx) { { title: "✓ #{payload[:name] || payload[:match]}", sub: nil } },
  execute:     ->(payload, ctx) {
    order = Buddy::Deliveries.arrived!(user: ctx.user, match: payload[:match])
    { name: order.name }
  },
  receipt:     ->(result, _ctx) { "**#{result[:name]}** marked as arrived" },
)
