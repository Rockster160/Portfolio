Buddy::Tools.register(
  name:        :search_email,
  summary:     "Search the person's EMAIL - did someone write back, what a message said, a " \
               "confirmation number or receipt in their inbox. Reads one in full by id.",
  description: <<~TXT,
    Search the mail that came into their inbox, archived mail included, and
    read any one message in full. This is the only way you can see their email:
    never guess what a message said or whether one came, and never say you
    can't check.

    - "did the vet ever email back?"
    - "what was the confirmation number for the hotel?"
    - "what did Chelsea forward me this morning?"
    - "anything from the bank this week?"

    Not this tool: what was said in THIS chat is `search_conversations`, and a
    package on its way is `check_deliveries`.

    `query` takes the emails page's own search syntax. Bare words match the
    subject, the opening lines, either person's name or address, and tags - not
    the full body. `from:vet`, `to:chelsea`, `subject:"lab results"`,
    `after:2026-10-01`, `before:2026-10-15` (before is exclusive), `has:attachment`,
    `is:unread`, `in:sent` for mail they sent. `OR`, `-` to exclude, parens to
    group, quotes around anything with a space. `from`, `to`, `subject`, `after`
    and `before` can go in as their own fields instead - they compile into the
    same thing.

    Search for words that would LITERALLY be in the mail: a name, a company, the
    thing it's about (`bloodwork`, `invoice`, `reservation`). A category word
    they used - "the vet", "the bank", "my landlord" - is rarely in the sender's
    name, so `from:vet` misses "Brightwater Animal Clinic". One or two words
    beat a long OR chain; widen by dropping words, not adding them.

    Matches come back in this same turn, newest first, with an id each. When
    the answer is inside a message rather than its subject - a number, a time,
    what they actually asked - call this again with `id` to read it, and answer
    from what it says. Read-only: nothing is marked read, sent or archived.
  TXT
  feature:     :email,
  args:        {
    query:   { type: :string,  required: false, description: "Search syntax or plain words" },
    from:    { type: :string,  required: false, description: "A sender's actual name, address or domain - never a category like vet, bank or doctor" },
    to:      { type: :string,  required: false, description: "A recipient's actual name, address or domain" },
    subject: { type: :string,  required: false, description: "Words in the subject line" },
    after:   { type: :string,  required: false, description: "On or after this date, YYYY-MM-DD" },
    before:  { type: :string,  required: false, description: "Before this date, YYYY-MM-DD" },
    id:      { type: :integer, required: false, description: "Read this one message in full, from a search's results" },
    limit:   { type: :integer, required: false, default: Buddy::EmailSearch::LIMIT, description: "How many matches (1-20)" },
  },
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, _ctx) { { summary: "Search email", resolved: {} } },
  label:       ->(payload, _ctx) { payload[:id].present? ? "Read email ##{payload[:id]}" : "Search email" },
  execute:     ->(payload, ctx) {
    if payload[:id].present?
      email = ctx.user.emails.find_by(id: payload[:id])
      raise "No email ##{payload[:id]} in their mail" if email.nil?

      next {
        email: Buddy::EmailSearch.read(email, ctx.user),
        how:   "The message itself. Answer from what it says, in your own words - quote only the " \
               "piece they asked for (a number, a time). If `partial`, the body couldn't be read " \
               "and this is only the opening; say so if the answer isn't in it.",
      }
    end

    fields = payload.slice(*Buddy::EmailSearch::FIELDS)
    search = ->(given) {
      Buddy::EmailSearch.call(
        user:  ctx.user,
        query: payload[:query],
        limit: payload[:limit] || Buddy::EmailSearch::LIMIT,
        **given,
      )
    }
    found = search.call(fields)

    # A sender is usually named the way the person thinks of it ("the vet")
    # rather than the way the mail is signed ("Brightwater Animal Clinic"), so
    # when the words would have found something the sender filter is dropped
    # once rather than reporting the mail as never having come.
    dropped = nil
    if found[:total].zero? && payload[:query].present? && fields.values_at(:from, :to).any?(&:present?)
      wider = search.call(fields.except(:from, :to))
      if wider[:total].positive?
        dropped = fields.slice(:from, :to).compact_blank.map { |key, value| "#{key}:#{value}" }.join(" ")
        fields = fields.except(:from, :to)
        found = wider
      end
    end
    rows = Buddy::EmailSearch.rows(found[:emails], ctx.user)

    {
      searched: Buddy::EmailSearch.describe(payload[:query], fields).presence,
      dropped:  (if dropped
                   "#{dropped} matched nothing, so these match the words alone - check the sender " \
                     "is the one they meant before saying it's from them."
                 end),
      total:    found[:total],
      emails:   rows,
      problems: found[:problems],
      how:      (
        if rows.any?
          "Newest first#{" - #{rows.length} of #{found[:total]} shown" if found[:total] > rows.length}. " \
            "Tell them what you found in your own words, not as a list of rows. When the answer is " \
            "inside a message rather than its subject, read it now with `id`."
        else
          "Nothing matched#{" (#{found[:problems].join("; ")})" if found[:problems]}. Before saying " \
            "you couldn't find it, search once more with fewer words: drop `from` if it was a " \
            "category like vet or bank, and keep the one word the mail would really contain."
        end
      ),
    }.compact
  },
)
