Buddy::Tools.register(
  name:        :add_job_note,
  feature:     :job_search,
  description: <<~TXT,
    Log a beat on one of their job applications - a reply came in, a call
    happened, an interview got booked, an offer or a rejection landed. The
    board and everything already on it is in the `job_search` context section;
    fetch that before calling this so you're attaching to a company that's
    really there.

    **This one WAITS FOR A TAP.** Nothing is written when you call it - the row
    is an offer, and the tense rules for a tap-to-run row apply in full. Never
    say you've got it, marked it, or logged it.

    **Name the company they named, or name none.** `company` is matched against
    what is really on the board, and if you pass something they didn't say, the
    row offers to change the wrong application's history. Passing a DIFFERENT
    company because the one they named isn't on the board is the specific
    failure: it settled CSC Generation as rejected when the sentence was about
    Corporate Tools, whose row wasn't visible because it was already closed. If
    what they named isn't there, say so and ask - an application you can't see
    is not the same thing as an application that isn't theirs.

    `company` is fuzzy - the name off an email footer is fine, "CSC Generation,
    Inc." finds "CSC Generation". SETTLED applications match too: one they were
    rejected from is still a thing that happened to them and still takes a note.

    `tag` is what KIND of beat it was, and it does more than colour the row:
    logging `offer`, `rejected` or `withdrew` settles the whole application,
    because having to then go and change a dropdown saying the same thing is
    how a tracker goes stale. Reach for those three only when the mail actually
    says so. `note` is the default and just means "this happened".

    `email_id` is the piece that makes this worth doing from a message rather
    than the page: pass the number from `recent_mail` and the note is stamped
    with that email's date, its sender, and a link straight back to it. Leave
    it off for something they told you about out loud.

    `occurred_at` is WHEN it happened, and it matters for the same reason
    `email_id` does. Mail that came in on Friday and got mentioned on Monday
    belongs on Friday, and the timeline is read in that order. `email_id`
    already carries its own date, so pass one or the other, never both. Use
    this when a message was announced to you and there's no email number to
    hand - the arrival time will be in what you were told.

    `follow_up_at` is for when they say they'll chase it - it puts a task on
    the agenda, so only set it if they actually said they'd come back to this.

    `summary` is one line saying what the note SAYS, and it exists so `note`
    never has to be shortened. It is what the card shows them; `note` is what
    gets kept. When you are logging a message word for word, the card reading
    "Hi Rocco," tells them nothing - put the gist here and leave the words
    where they belong. Nothing stores it.
  TXT
  args:        {
    company:      { type: :string, required: true, description: "Which application - fuzzy, the company name" },
    note:         { type: :string, required: false, description: "What happened, in their words. Required unless a tag says it" },
    summary:      { type: :string, required: false, description: "One line of what `note` says, for the card only. Never stored" },
    tag:          {
      type:        :enum,
      required:    false,
      default:     :note,
      values:      JobNote.tags.keys.map(&:to_sym),
      description: "The kind of beat. offer/rejected/withdrew also settle the application",
    },
    email_id:     { type: :integer, required: false, description: "The email this came from, from recent_mail" },
    occurred_at:  { type: :iso_time, required: false, description: "When it happened, if no email_id carries the date" },
    spoke_to:     { type: :string, required: false, description: "Who they dealt with, if a person was named" },
    follow_up_at: { type: :iso_time, required: false, description: "Only if they said they'd chase it" },
  },
  confirm:     ->(payload, ctx) {
    job = Buddy::JobHunt.resolve_application(ctx.user, payload[:company])
    raise "no application matching \"#{payload[:company]}\"" if job.nil?

    tag  = payload[:tag].presence || :note
    body = payload[:note].to_s.strip
    # The model's own validation, said early: an untagged note IS its words, so
    # a bare `note` with nothing in it is a row that reads as nothing.
    raise "nothing to log - say what happened" if body.empty? && tag.to_s == "note"

    email = ctx.user.emails.find_by(id: payload[:email_id]) if payload[:email_id].present?
    raise "no email ##{payload[:email_id]}" if payload[:email_id].present? && email.nil?

    settles = JobNote::IMPLIED_STATUS[tag.to_s]
    summary = "Log **#{JobNote::TAG_LABELS[tag.to_s] || "Note"}** on **#{job.company}**?"
    summary += " That closes it as #{settles}." if settles

    {
      summary:  summary,
      resolved: {
        job_id:       job.id,
        company:      job.company,
        tag:          tag,
        note:         body,
        summary:      payload[:summary].presence,
        email_id:     email&.id,
        occurred_at:  payload[:occurred_at],
        spoke_to:     payload[:spoke_to].presence,
        follow_up_at: payload[:follow_up_at],
      },
    }
  },
  # `summary` wins over `note` on the CARD and nowhere else. What gets kept is
  # the message's own words, and the first eighty characters of those are a
  # greeting — "Hi Rocco, I'm not able to provide feedback per the advice from"
  # is the part of a rejection that says least about it.
  label:       ->(payload, _ctx) {
    label = JobNote::TAG_LABELS[payload[:tag].to_s] || "Note"
    sub   = payload[:summary].presence || payload[:note]
    { title: "💼 #{label} — #{payload[:company]}", sub: sub.to_s.truncate(80).presence }
  },
  # The same beat said twice in one turn is one beat.
  merge_key:   ->(payload) { "add_job_note:#{payload[:company]}:#{payload[:tag]}:#{payload[:note].to_s.downcase.strip}" },
  # Level 3: an offer that writes nothing until it's tapped.
  #
  # It was level 2 - written on arrival, pre-checked, undo by unchecking - and
  # that is too much trust for this. The model picks WHICH application a beat
  # lands on, and when the one they named isn't on the visible board it will
  # pick a neighbour rather than stop: prod 5759 settled CSC Generation as
  # rejected off a sentence about Corporate Tools. A pre-checked row makes the
  # read-back the only defence, and reading "Rejected — CSC Generation" as a
  # statement of fact is exactly what a level-2 row invites.
  #
  # A settling tag also moves the application's whole status, so the cost of
  # being wrong isn't one stray row - it closes an application that is still
  # open. That belongs behind a tap.
  level:       3,
  # The value is one particular thing that happened on one particular day.
  # Replaying it inside a routine next month is meaningless.
  routinable:  false,
  execute:     ->(payload, ctx) {
    job = ctx.user.job_applications.find_by(id: payload[:job_id])
    raise "that application is gone" if job.nil?

    email = ctx.user.emails.find_by(id: payload[:email_id]) if payload[:email_id].present?
    was   = job.status

    note = job.notes.create!(
      body:         payload[:note].presence,
      tag:          payload[:tag],
      # The mail's own clock, so the timeline reads in the order things
      # actually happened rather than in the order they were logged. Mail that
      # arrived on Friday and got mentioned on Monday belongs on Friday. An
      # email we hold answers this itself; mail we were only told about has to
      # be handed the time, and falling back to `now` is the last resort rather
      # than the norm.
      occurred_at:  email&.timestamp || payload[:occurred_at] || Time.current,
      source:       (email ? "Email" : nil),
      url:          (email ? Rails.application.routes.url_helpers.email_url(id: email.id) : nil),
      spoke_to:     payload[:spoke_to].presence,
      follow_up_at: payload[:follow_up_at],
    )
    job.touch_activity!

    # Stamped back onto the email so the context section can say this one is
    # already on the board. Without it the same mail keeps reading as
    # outstanding and gets offered again every time the board is looked at.
    email&.update!(job_triage: email.job_triage.merge(job_note_id: note.id))

    job.reload
    summary = "took that note back off #{job.company}"
    reverts = [{ op: "created", model: "JobNote", id: note.id, summary: summary }]
    # A settling tag moved the application as well as adding a row, and
    # JobNote#settle_application bails on destroy - so without this second
    # descriptor an undo removes the note and leaves the job marked rejected.
    if job.status != was
      reverts << {
        op:      "updated",
        model:   "JobApplication",
        id:      job.id,
        before:  { "status" => was },
        summary: summary,
      }
    end

    {
      company: job.company,
      label:   note.tag_label,
      status:  job.status,
      settled: job.status != was,
      url:     "#{Buddy::AppPages.url_for("/interviews")}/#{job.id}",
      reverts: reverts,
    }
  },
  # The company is the link. A receipt that says a row changed and gives no way
  # to go and look at it makes them go and find it, which is the trip the whole
  # card was for.
  receipt:     ->(result, _ctx) {
    company = result[:url].present? ? "[#{result[:company]}](#{result[:url]})" : "**#{result[:company]}**"
    base    = "Logged **#{result[:label]}** on #{company} ✓"
    result[:settled] ? "#{base} — marked #{result[:status]}" : base
  },
)
