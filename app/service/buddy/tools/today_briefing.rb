Buddy::Tools.register(
  name:        :today_briefing,
  description: <<~TXT,
    Deliver the "Today" briefing. It composes and posts a whole message of its
    own, so calling it is handing the turn over rather than getting an answer
    back.

    Almost nothing said to you is a reason to call this. "What's on today" is an
    ordinary question you answer from your own context, and this would answer it
    by posting a second message underneath yours. Reach for it only when they
    ask for the briefing ITSELF ("send me my Today", "run my Today again").

    The morning one is on a reminder and needs nothing from you. When they want
    it EARLIER, LATER or STOPPED, that reminder is the thing to change - it's in
    `upcoming_reminders` - so `move_reminder` and `cancel_reminder` are the
    tools, not this one. What the briefing SAYS isn't adjustable from anywhere;
    a request to change its content is a conversation, not a call.
  TXT
  args:        {},
  # Level 1: it's the whole reply, so there is nothing to tick. The briefing
  # arrives as its own message a beat later, the same way it does on a tap.
  level:       1,
  # Posts a whole message of its own, so whatever fires it does so without a
  # heading over the top (see Buddy::ReminderFirer#run_action). The briefing's
  # opening line is the thing its prompt works hardest on; an announcement lands
  # directly on it.
  speaks:      true,
  # Its schedule is a reminder, deliberately, so that moving and cancelling are
  # the tools that already exist for those. Saving it into a routine would be a
  # second way to fire the same thing, with its own copy of the timing question.
  routinable:  false,
  confirm:     ->(_payload, ctx) {
    raise "no conversation to brief in" if ctx.conversation.nil?

    { summary: "Send the Today briefing?", resolved: {} }
  },
  label:       ->(_payload, _ctx) { { title: "Today" } },
  execute:     ->(_payload, ctx) {
    msg = Buddy::TodayBriefing.deliver!(ctx.user, ctx.conversation, scheduled: true)
    { delivered: msg.present?, message_id: msg&.id }
  },
  # No receipt. The briefing IS the visible result, and a "Called Today ✓" pill
  # over a message that opens with a greeting is the chip saying what the next
  # line is about to say.
  receipt:     ->(_result, _ctx) {},
)
