Buddy::Tools.register(
  name:        :search_ideas,
  description: <<~TXT,
    Look back through everything they've ever handed you to hold, including
    threads that were finished or dropped. The results come straight back to you
    in this turn.

    Your prompt already carries the still-open ones, capped and oldest-first, so
    don't call this to answer "what am I holding". Call it when they reach for
    something that ISN'T in that list:

    - "what was that thing I said about the greenhouse?"
    - "didn't I have an idea about the basement lights ages ago?"
    - "have I mentioned this before?" - which is worth checking BEFORE stashing
      something that sounds familiar, so a thought they've circled four times
      becomes one thread rather than four piles.
    - "what have I been chewing on lately?" - `threads_only: true` for the ones
      they've actually come back to.

    `query` matches the seed, your summary, AND every note, which matters: on a
    thought that's been added to a few times the words they remember are usually
    in the notes. Leave it empty to just list the most recently touched.

    Set `open_only: true` to exclude finished and dropped ones. The default
    includes them, because someone asking about an old thought rarely remembers
    whether they ever closed it out.

    To read one thread in full, `read_idea`.
  TXT
  args:        {
    query:        { type: :string,  required: false, description: "Words to look for, across seeds and notes" },
    open_only:    { type: :boolean, required: false, default: false, description: "Exclude finished and dropped" },
    threads_only: { type: :boolean, required: false, default: false, description: "Only ideas they've added to" },
  },
  # Level 1 + answers: this is a lookup, so it settles inside the turn and hands
  # the results back instead of leaving a checkbox asking permission to look.
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, _ctx) { { summary: "Search held ideas", resolved: {} } },
  label:       ->(_payload, _ctx) { "Search held ideas" },
  execute:     ->(payload, ctx) {
    found = Buddy::IdeaSearch.call(
      user:         ctx.user,
      query:        payload[:query],
      status:       ActiveModel::Type::Boolean.new.cast(payload[:open_only]) ? :live : :all,
      threads_only: ActiveModel::Type::Boolean.new.cast(payload[:threads_only]),
    )
    ideas = found[:ideas]

    {
      query:   payload[:query].presence,
      total:   found[:total],
      showing: ideas.length,
      ideas:   Buddy::IdeaSearch.rows(ideas),
      how:     (
        if ideas.any?
          "Newest-touched first. Each line is `#id`, the label, then its tags — how many notes it has and " \
            "how long since they last added to it. Talk about these the way they'd talk about them; don't " \
            "read the tags out. `read_idea` opens one in full, `elaborate_idea` adds to one, and if the thing " \
            "they just said belongs on one of these, that is an elaboration rather than a new stash."
        else
          "Nothing matched, and that IS the answer — say you've got nothing on it rather than guessing at " \
            "what they might have meant. If they're telling you something new, `stash_idea` it."
        end
      ),
    }.compact
  },
)
