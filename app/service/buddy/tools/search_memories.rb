Buddy::Tools.register(
  name:        :search_memories,
  description: <<~TXT,
    Everything you've kept about this person that isn't a standing preference.

    Your prompt carries their preferences — how they like things done — and
    nothing else. What they told you once, what happened to them, what they were
    worried about, the thing they said they'd regret forgetting: all of it is
    here, and none of it is in front of you until you ask.

    That means a blank is almost never the answer. When they reference something
    from the past — "the camping trip", "that thing with my mum", "what did I
    say about the boiler" — search before you say you don't have it.

    Two ways in, and they combine:

    - `tags` when the conversation names a SUBJECT. If they mention camping,
      search `tags: ["camping"]` and see what you're holding about camping. This
      is the one to reach for proactively — a memory that only surfaces when
      somebody asks for it by name is a memory nobody gets the use of. Their
      stash categories (me / home / work) match here too.
    - `query` when they're groping for a half-remembered thing and the words
      they'd use are in the prose. Matches the content, your summary, AND every
      note on a thread.

    `min_severity` narrows to things that actually matter — use it when you want
    the weighty ones rather than everything you happen to hold.

    Results come straight back to you in this turn.
  TXT
  args:        {
    query:        { type: :string,  required: false, description: "Words to look for across content, summaries and notes" },
    tags:         { type: :string,  required: false, description: "Comma-separated subjects, e.g. \"camping, work\"" },
    min_severity: { type: :integer, required: false, description: "0-100. Only things at least this important" },
    open_only:    { type: :boolean, required: false, default: false, description: "Exclude finished and dropped" },
  },
  # A lookup, so it settles inside the turn and hands the results back rather
  # than leaving a checkbox asking permission to look something up.
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, _ctx) { { summary: "Search memories", resolved: {} } },
  label:       ->(_payload, _ctx) { "Search memories" },
  execute:     ->(payload, ctx) {
    tags = payload[:tags].to_s.split(",").map(&:strip).reject(&:empty?)
    found = Buddy::MemorySearch.call(
      user:   ctx.user,
      query:  payload[:query],
      tags:   tags,
      status: ActiveModel::Type::Boolean.new.cast(payload[:open_only]) ? :live : :all,
    )
    memories = found[:memories]
    floor    = payload[:min_severity].to_i
    memories = memories.select { |m| m.severity >= floor } if floor.positive?

    {
      query:    payload[:query].presence,
      tags:     tags.presence,
      total:    found[:total],
      showing:  memories.length,
      memories: Buddy::MemorySearch.rows(memories),
      how:      (
        if memories.any?
          "Most important first. Each line is `#id`, the label, then what kind of record it is and its " \
            "tags. Use these the way they'd use them — reference the thing, don't read the tags out. " \
            "Something with a note count is a THREAD they've come back to; `read_idea` opens one in full."
        else
          "Nothing matched. That IS an answer worth giving plainly — say you don't have anything on it " \
            "rather than guessing at what they might have meant. If they're telling you something new, " \
            "it'll get kept on its own without you doing anything."
        end
      ),
    }.compact
  },
)
