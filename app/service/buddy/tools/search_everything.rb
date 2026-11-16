Buddy::Tools.register(
  name:        :search_everything,
  summary:     "Search every kind of record at once by name, when it isn't clear which kind the " \
               "thing they mean is.",
  description: <<~TXT,
    One search across everything the person keeps: chores, logged events, lists
    and their items, boxes and the things in them, calendar items, contacts,
    timers, pages, mail and what you've saved about them. For a name that
    could be any of those - "the filter", "the vitamins", "Dishes" - where
    picking one kind and searching it alone could miss the one they meant.

    `query` is the name in their words. Every kind that has a match comes back
    as its own group, each hit with its id and what it is, and each group with
    the tools that act on that kind.

    Choose from what came back, in this same turn:
    - One hit fits what they asked: act on it with its group's tool.
    - Hits in several kinds: weigh what they asked for against what each kind
      is. Doing something to a thing points one way, logging that it happened
      another, finding where it is another. When it still reads two ways, ask
      which, naming the kinds.
    - Nothing came back: say so, and ask for another word.
  TXT
  args:        {
    query: { type: :string, required: true, description: "The name to find, in their words" },
  },
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, _ctx) { { summary: "Search everything", resolved: {} } },
  label:       ->(payload, _ctx) { "Search everything for #{payload[:query]}" },
  execute:     ->(payload, ctx) {
    query  = payload[:query].to_s.squish
    groups = Buddy::SearchEverything.call(user: ctx.user, conversation: ctx.conversation, query: query)

    {
      searched: query,
      groups:   groups,
      how:      (
        if groups.any?
          "Each group is one kind of record. Pick the hit that fits what they asked and act on " \
            "it with a tool from its group's `acts_with`, using the id shown. If it still reads " \
            "two ways across groups, ask which."
        else
          "Nothing anywhere is called that. Tell them so, and ask for another word for it."
        end
      ),
    }
  },
)
