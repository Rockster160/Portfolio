Buddy::Tools.register(
  name:        :list_reminders,
  description: <<~TXT,
    Show the person their reminders so they can see and remove them. Use when
    they ask to see / list / review / manage / check what reminders they have
    ("what reminders do I have", "show my reminders", "what am I being reminded
    about", "cancel some reminders"). Covers BOTH clock-time reminders and
    condition-based ones ("when I get to Costco").

    THIS CALL IS THE ANSWER. It draws the list, with a tappable row per
    reminder, directly under your reply - and it is the only thing that draws
    it. Writing a sentence that introduces the list without calling this leaves
    them staring at a lead-in with nothing beneath it. So call it, then say
    something short and in your own words above it; don't recite the reminders
    in prose, the rows already do that.

    To cancel ONE specific reminder by name, prefer cancel_reminder instead.

    **"Notifications" is not this word.** Somebody saying they get too many
    notifications, or asking how to stop being alerted, may mean the alerts on
    their phone - which are not reminders, are not listed here, and are not
    something you can turn off. Ask which they mean before drawing anything.
    Only "reminder" in their own words, or a reminder they name, reaches this.
  TXT
  # Prod 5808, and it cost a round: "It looks like you have a lot of
  # notifications how do I go through those so they [stop] alerting me anymore"
  # drew the reminder list, and the answer back was "no they are not the
  # reminders they are like notifications on my phone maybe it's every time you
  # speak". Nothing in the description said "notifications" - the model
  # generalized, which is what an unbounded verb list invites.
  args:        {},
  # Level 1 (auto), but NOT an `answers:` tool: what it produces is for the
  # person, not for the model. It draws rows in the thread rather than handing
  # findings back, so it stays on the execute-after-the-reply path.
  auto:        true,
  confirm:     ->(_payload, _ctx) { { summary: "List reminders", resolved: {} } },
  label:       ->(_payload, _ctx) { "List reminders" },
  execute:     ->(_payload, ctx) {
    next { relayed: false } if ctx.conversation.nil?

    Buddy::ReminderList.render(user: ctx.user, conversation: ctx.conversation)
    { relayed: true }
  },
  # The list message IS the output, so opt out of the activity chip on success.
  receipt:     ->(result, _ctx) {
    next nil if result[:relayed]

    "Couldn't pull up your reminders right now."
  },
)
