Buddy::Tools.register(
  name:        :search_conversations,
  description: <<~TXT,
    Look back through what was actually SAID — this thread, or every thread they
    have with any of their companions.

    This is different from `search_memories`. That one searches what you chose
    to keep; this one searches the transcript, for the times nothing got kept
    because at the moment it was said it didn't look worth keeping:

    - "what was that thing I was talking to Moss about earlier today?"
    - "I told you I need to pick my cousins up from the airport — what day?"
    - "didn't I mention the boiler at some point?"
    - checking whether they've already told you something, before you ask them
      for it a second time.

    `scope: "all"` reaches every Buddy thread they have, which is what a
    question naming a different companion needs — someone asking what they said
    to Moss is telling you the answer isn't in this thread. `scope: "thread"`
    (the default) stays here.

    `days` narrows to recent history when they've said "earlier today" or "last
    week". Leave it off to search everything.

    You only ever see this person's own threads. Results come back in this turn.
  TXT
  args:        {
    query: { type: :string,  required: true,  description: "Words to look for in what was said" },
    scope: { type: :enum,    required: false, values: %i[thread all], description: "This thread, or all of theirs" },
    days:  { type: :integer, required: false, description: "Only look back this many days" },
  },
  # A lookup: settles inside the turn, no permission checkbox.
  auto:        true,
  answers:     true,
  confirm:     ->(payload, _ctx) { { summary: "Search what was said about #{payload[:query]}", resolved: {} } },
  label:       ->(payload, _ctx) { "Search conversations: #{payload[:query]}" },
  execute:     ->(payload, ctx) {
    scope = payload[:scope].presence&.to_sym || :thread
    found = Buddy::ConversationSearch.call(
      user:         ctx.user,
      query:        payload[:query],
      conversation: ctx.conversation,
      scope:        scope,
      days:         payload[:days],
    )
    messages = found[:messages]

    {
      query:    payload[:query],
      scope:    scope,
      total:    found[:total],
      showing:  messages.length,
      messages: Buddy::ConversationSearch.rows(messages, ctx.user),
      how:      (
        if messages.any?
          "Newest first. Each line is when it was said, which thread it was in, who said it, and the " \
            "words. Answer from these — they're a record of the actual conversation, so you can quote " \
            "or paraphrase without hedging. If the answer they want isn't in the matched lines but you " \
            "can see it was part of a longer exchange, say what you've got and what you're missing."
        else
          "Nothing matched. Say so plainly rather than reconstructing what they probably said — if it " \
            "isn't in the transcript, you don't know it. Offer to search different words, or with " \
            "`scope: \"all\"` if this was only the current thread."
        end
      ),
    }.compact
  },
)
