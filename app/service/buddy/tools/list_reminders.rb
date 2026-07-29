Buddy::Tools.register(
  name:        :list_reminders,
  description: <<~TXT,
    Show the person their reminders so they can see and remove them. Use when
    they ask to see / list / review / manage / check what reminders they have
    ("what reminders do I have", "show my reminders", "what am I being reminded
    about", "cancel some reminders"). Covers BOTH clock-time reminders and
    condition-based ones ("when I get to Costco"). It renders an interactive
    list right below your reply - each row is tappable to remove - so in THIS
    reply just give a short lead-in ("here's what you've got"); the list itself
    shows up on its own. To cancel ONE specific reminder by name, prefer
    cancel_reminder instead.
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
