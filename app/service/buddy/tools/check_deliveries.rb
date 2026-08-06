Buddy::Tools.register(
  name:        :check_deliveries,
  description: <<~TXT,
    Look up the packages on their way: what's coming, when it's due, who's
    carrying it, and what's already turned up. Built from the shipping emails
    that land in their inbox (Amazon, UPS, USPS, FedEx) plus anything added by
    hand, so it covers rather more than Amazon.

    Use it for "what's coming today", "did my X ship", "when's the desk getting
    here", "any packages this week", "has anything arrived". Use it too before
    saying you can't see their orders - you can, and answering "not from here"
    to "can you see my Amazon orders?" is the thing this exists to stop.

    `query` matches on words in the item's name, in any order, and also matches
    a carrier or a tracking number. Omit it for everything in the window. `days`
    is how far ahead to look (default 14). Anything overdue and anything that
    arrived in the last few days comes back regardless, since both are what
    people are usually asking about.

    Results come straight back to you in this same turn. Answer with them rather
    than reading the list out line by line; a date and a name is what they want.
  TXT
  feature:     :deliveries,
  args:        {
    query: { type: :string,  required: false, description: "Item name, carrier, or tracking number; words match in any order. Omit for all" },
    days:  { type: :integer, required: false, default: 14, description: "How far ahead to look (1-120)" },
  },
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, ctx) {
    raise "the delivery list isn't part of this person's setup" unless Buddy::Deliveries.available?(ctx.user)

    { summary: "Check deliveries", resolved: {} }
  },
  label:       ->(_payload, _ctx) { "Deliveries" },
  execute:     ->(payload, ctx) {
    days  = (payload[:days] || Buddy::Deliveries::DEFAULT_DAYS).to_i
    query = payload[:query].to_s.strip
    found = Buddy::Deliveries.call(user: ctx.user, query: query, days: days)

    {
      searched:   query.presence,
      days:       days,
      deliveries: found[:rows],
      total:      found[:count],
      how:        (
        if found[:rows].any?
          "Soonest first. Say what's coming in your own words - the name and when, not the " \
            "whole line. \"was due\" on something means the date passed and nothing confirmed it " \
            "arrived, which is worth flagging. To add one they've told you about, call " \
            "`track_delivery`; to fix a name or move a date, `update_delivery`; when they say " \
            "something turned up, `delivery_arrived`. A name like \"Office item\" or \"Lighting " \
            "& Fans items\" came off an email's category rather than the thing itself - if they " \
            "tell you what it really is, that's worth correcting."
        else
          "Nothing matching in that window. Say so plainly - it means no email has come in " \
            "about one, not that they haven't ordered anything. Offer to note it with " \
            "`track_delivery` if they know something's coming."
        end
      ),
    }.compact
  },
)
