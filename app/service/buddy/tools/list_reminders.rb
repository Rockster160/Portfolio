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
  TXT
  args:        {},
  # Level 1 (auto): a read that renders its own inline list (like search_events
  # relays its own follow-up), so there's no checkbox to confirm and no chip.
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
