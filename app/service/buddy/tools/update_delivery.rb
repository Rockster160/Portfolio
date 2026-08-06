Buddy::Tools.register(
  name:        :update_delivery,
  description: <<~TXT,
    Correct something already on the delivery list. Use when they tell you a
    package has changed or was filed wrong - "the desk is coming Friday now",
    "that one's actually the monitor stand", "here's the tracking for the
    mattress", "the Wayfair order pushed to next week".

    Most rows are built from a shipping email, and the guesses in them are worth
    fixing: an item named off a category ("Office item", "Lighting & Fans
    items") is the usual one, and a date the sender has since moved is the
    other. This is also how a tracking number or an order link gets attached
    after the fact.

    `match` is a few words from the item as it stands NOW. Pass only the fields
    that are changing - anything you leave out keeps its current value, so a
    rename won't drop the tracking number. To say a package turned up, that's
    `delivery_arrived`; to put a brand new one on the list, `track_delivery`.
  TXT
  feature:     :deliveries,
  args:        {
    match:    { type: :string, required: true,  description: "A few words from the item's name as it stands now" },
    name:     { type: :string, required: false, description: "What it should be called instead" },
    when:     { type: :string, required: false, description: "New expected day: \"today\", \"tomorrow\", \"friday\", \"N days/weeks\", or YYYY-MM-DD" },
    tracking: { type: :string, required: false, description: "Tracking number, if they gave one" },
    url:      { type: :string, required: false, description: "Order or tracking link, if they gave one" },
  },
  auto:        true,
  confirm:     ->(payload, ctx) {
    raise "the delivery list isn't part of this person's setup" unless Buddy::Deliveries.available?(ctx.user)

    order = Buddy::Deliveries.find(ctx.user, payload[:match])
    raise "nothing on the delivery list matches #{payload[:match].to_s.strip.inspect}" if order.nil?

    said = payload[:when].to_s.strip
    on   = said.present? ? ctx.end_of_day_for(said)&.to_date : nil
    raise "couldn't read #{said.inspect} as a day" if said.present? && on.nil?

    # Nothing to change is a mistake worth catching here: it would otherwise
    # save an identical row, fire an update trigger, and report success.
    if [payload[:name], said, payload[:tracking], payload[:url]].all? { |v| v.to_s.strip.blank? }
      raise "nothing to change on #{order.name} - say what should be different"
    end

    { summary: "Update #{order.name}", resolved: { was: order.name, on_iso: on&.iso8601 } }
  },
  label:       ->(payload, _ctx) { { title: payload[:name].presence || payload[:was].to_s, sub: payload[:on_iso].presence } },
  execute:     ->(payload, ctx) {
    on = (Date.parse(payload[:on_iso].to_s) if payload[:on_iso].present?)
    order = Buddy::Deliveries.edit!(
      user:     ctx.user,
      match:    payload[:match],
      name:     payload[:name],
      on:       on,
      tracking: payload[:tracking],
      url:      payload[:url],
    )
    { was: payload[:was], name: order.name, on: order.delivery_date }
  },
  receipt:     ->(result, ctx) {
    due      = (Date.parse(result[:on].to_s) rescue nil)
    when_str = (Buddy::Deliveries.friendly(due, ctx.user.perceived_today) if due)
    renamed  = result[:was].present? && result[:was] != result[:name]

    head = renamed ? "**#{result[:was]}** is now **#{result[:name]}**" : "Updated **#{result[:name]}**"
    "#{head}#{" · #{when_str}" if when_str}"
  },
)
