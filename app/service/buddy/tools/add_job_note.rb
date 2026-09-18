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

    **One company can hold several applications.** Applying to three jobs at one
    place is three rows with three separate outcomes, so when the board shows
    more than one for a company, `company` alone cannot say which and `role` is
    what does. Pass it whenever the mail names a job title. If you leave it off
    and the company has several, this comes back naming the roles - answer it
    with one of them rather than picking.

    `tag` is what KIND of beat it was, and it does more than colour the row:
    logging `offer`, `rejected` or `withdrew` settles the whole application,
    because having to then go and change a dropdown saying the same thing is
    how a tracker goes stale. Reach for those three only when the mail actually
    says so. `note` is the default and just means "this happened".

    **An ask for times is `availability`, not `scheduled`.** `scheduled` means a
    time is AGREED and puts it on their calendar as a timed event, so using it
    for "send me your availability" invents an interview that does not exist.
    `availability` is the one beat on the list waiting on THEM - a link to fill
    in, times to send back - and a `follow_up_at` on it puts "Send availability"
    on the agenda as a task. Use `scheduled` only once the mail names the slot.

    **An ATS receipt is `acknowledged`, not `applied` and not `heard_back`.**
    "Thanks for applying, a real human will review this" is a machine saying it
    arrived. `applied` is a thing THEY did, so putting it on a robot's reply
    says they applied twice; `heard_back` means a PERSON wrote, which is the
    beat actually being waited on, and a robot wearing it makes a live
    application look answered.

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

    **`follow_up_at` means two different things, and the tag decides which.**

    On a `scheduled` note it IS the interview, it is what puts the appointment
    on their calendar as a timed event, and it is REQUIRED - a Scheduled note
    with no time says an interview exists and cannot say when, which is the one
    shape this tool refuses. Read the time off the mail; it is in there, in
    their own zone, because that is what the mail was sent to tell them.
    `duration_minutes` goes with it ("we'll chat for ~20 minutes", an invite
    reading 2:00-2:20), and without one an interview is booked for an hour.

    On every other tag it is a chase YOU owe THEM, it goes on the agenda as a
    task, and it is optional - set it only if they actually said they'd come
    back to this. An `availability` note is the useful middle: the date is when
    the times are owed by, and the task reads "Send availability".

    `summary` is one line saying what the note SAYS, and it exists so `note`
    never has to be shortened. It is what the card shows them; `note` is what
    gets kept. When you are logging a message word for word, the card reading
    "Hi Rocco," tells them nothing - put the gist here and leave the words
    where they belong. Nothing stores it.
  TXT
  args:        {
    company:          { type: :string, required: true, description: "Which application - fuzzy, the company name" },
    role:             { type: :string, required: false, description: "Which job there, when the company has more than one on the board" },
    note:             { type: :string, required: false, description: "What happened, in their words. Required unless a tag says it" },
    summary:          { type: :string, required: false, description: "One line of what `note` says, for the card only. Never stored" },
    tag:              {
      type:        :enum,
      required:    false,
      default:     :note,
      values:      JobNote.tags.keys.map(&:to_sym),
      description: "The kind of beat. An ATS receipt is `acknowledged`; an ask for times is `availability`, not `scheduled`. offer/rejected/withdrew also settle the application",
    },
    email_id:         { type: :integer, required: false, description: "The email this came from, from recent_mail" },
    occurred_at:      { type: :iso_time, required: false, description: "When it happened, if no email_id carries the date" },
    spoke_to:         { type: :string, required: false, description: "Who they dealt with, if a person was named" },
    follow_up_at:     {
      type:        :iso_time,
      required:    false,
      description: "On `scheduled` this IS the interview and is REQUIRED. Elsewhere, only if they said they'd chase it",
    },
    duration_minutes: {
      type:        :integer,
      required:    false,
      description: "How long the interview runs, if the mail says. Defaults to an hour",
    },
  },
  confirm:     ->(payload, ctx) {
    # One company can hold several applications, and then the company name alone
    # cannot say which. Everything that might name the role goes in: the `role`
    # arg, the card's own line, and the words of the mail.
    said = [payload[:role], payload[:summary], payload[:note]].compact_blank.join(" ")
    job  = Buddy::JobHunt.resolve_application(ctx.user, payload[:company], said: said)

    if job.nil?
      rows = Buddy::JobHunt.applications_for(ctx.user, payload[:company])
      raise "no application matching \"#{payload[:company]}\"" if rows.empty?

      # Answerable: it says which roles are there, so the next call can name one.
      # A guess here is silent and permanent - three Aledade jobs with three
      # separate outcomes were set to resolve as one.
      roles = rows.map { |row| row.role.presence || "(no role recorded)" }
      raise "#{rows.first.company} has #{rows.size} applications on the board - " \
            "pass `role` saying which: #{roles.join(" / ")}"
    end

    tag  = payload[:tag].presence || :note
    body = payload[:note].to_s.strip
    # The model's own validation, said early: an untagged note IS its words, so
    # a bare `note` with nothing in it is a row that reads as nothing.
    raise "nothing to log - say what happened" if body.empty? && tag.to_s == "note"

    email = ctx.user.emails.find_by(id: payload[:email_id]) if payload[:email_id].present?
    raise "no email ##{payload[:email_id]}" if payload[:email_id].present? && email.nil?

    # The description says so; this enforces it. A `scheduled` note with no time
    # writes NOTHING to the calendar - JobNote#sync_follow_up returns early on a
    # blank `follow_up_at` - so the row reads "Interview booked" on the board
    # and the day it is booked for stays empty. Prod 56/57: two Scheduled notes
    # for one ApartmentIQ interview, both with the time sitting in their own
    # summary line and neither with it in the field.
    at = payload[:follow_up_at]
    if tag.to_s == "scheduled" && at.blank?
      raise "a scheduled interview needs its time - pass follow_up_at, or use a different tag"
    end

    # Two Scheduled notes at the same minute are one interview announced twice -
    # the calendar invite and the confirmation email arrive as separate mail,
    # five seconds apart, and each one is its own turn so no merge_key can see
    # the other. Left alone it books the appointment on the agenda TWICE.
    # `filed` is excluded because it IS this mail: Buddy::JobMailOffer files an
    # arriving mail on its row before this card is raised, so without the
    # exclusion the duplicate checks below read that row as a clash with itself.
    filed = job.notes.find_by(id: email&.job_triage&.[](:job_note_id))
    twin  = job.notes.where(tag: :scheduled, follow_up_at: at).where.not(id: filed&.id)
    if tag.to_s == "scheduled" && twin.exists?
      raise "#{job.company} is already booked for then - log the words as a plain note instead"
    end

    # A SECOND acknowledgement on one row is nearly always a second ROLE.
    #
    # An ATS sends one "we received your application" per application, so a row
    # that already has one and is being handed another is the shape of two jobs
    # at one company collapsing onto one board entry.
    #
    # Three separate roles applied to at one company in a day:
    # `resolve_application` matches on company and nothing else, so notes for
    # two of them land on the third's row,
    # which reads `Principal Engineer - AI Data and Infrastructure`. Three jobs
    # with three separate outcomes were set to resolve as one.
    #
    # The role check is what keeps a genuine second mail on ONE job passing: if
    # the row's role is named in what arrived, this is that job and the note
    # belongs. Only a headline naming something else is refused, and refused
    # loudly enough to say what to do instead.
    if tag.to_s == "acknowledged" && job.notes.where(tag: :acknowledged).where.not(id: filed&.id).exists?
      said = [payload[:summary], payload[:note]].compact.join(" ")
      unless Buddy::JobHunt.role_named_in?(job, said)
        raise "#{job.company} already has an acknowledgement, and this one is not for " \
              "#{job.role.presence || "that role"} - if it is a different job there, open it " \
              "with add_job_application instead of adding to this one"
      end
    end

    settles = JobNote::IMPLIED_STATUS[tag.to_s]
    summary = "Log **#{JobNote::TAG_LABELS[tag.to_s] || "Note"}** on **#{job.company}**?"
    summary += " That closes it as #{settles}." if settles

    {
      summary:  summary,
      resolved: {
        job_id:           job.id,
        company:          job.company,
        tag:              tag,
        note:             body,
        summary:          payload[:summary].presence,
        email_id:         email&.id,
        occurred_at:      payload[:occurred_at],
        spoke_to:         payload[:spoke_to].presence,
        follow_up_at:     at,
        duration_minutes: payload[:duration_minutes],
      },
    }
  },
  # `summary` wins over `note` on the CARD and nowhere else. What gets kept is
  # the message's own words, and the first eighty characters of those are a
  # greeting — "Hi there, I'm not able to provide feedback per the advice from"
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
  # pick a neighbour rather than stop, settling one company as rejected off a
  # sentence about another. A pre-checked row makes the read-back the only
  # defence, and reading "Rejected — <company>" as a statement of fact is
  # exactly what a level-2 row invites.
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

    # One email is one beat: a mail already filed on this row is REVISED, not
    # filed twice. Buddy::JobMailOffer writes arriving mail onto its row as a
    # plain `note`, and this card is the reading of that same row.
    #
    # Scoped to `job.notes` on purpose — an `email_id` must never drag a note
    # filed against one application onto another. A mail nothing has filed, or
    # a beat mentioned out loud with no email at all, still creates.
    existing = job.notes.find_by(id: email&.job_triage&.[](:job_note_id))
    before   = existing&.slice(:tag, :body, :spoke_to, :follow_up_at, :duration_minutes)

    note = (existing || job.notes.new)
    note.assign_attributes(
      body:             payload[:note].presence,
      tag:              payload[:tag],
      # The mail's own clock, so the timeline reads in the order things
      # actually happened rather than in the order they were logged. Mail that
      # arrived on Friday and got mentioned on Monday belongs on Friday. An
      # email we hold answers this itself; mail we were only told about has to
      # be handed the time, and falling back to `now` is the last resort rather
      # than the norm.
      occurred_at:      email&.timestamp || payload[:occurred_at] || Time.current,
      source:           (email ? "Email" : nil),
      url:              (email ? Rails.application.routes.url_helpers.email_url(id: email.id) : nil),
      spoke_to:         payload[:spoke_to].presence,
      follow_up_at:     payload[:follow_up_at],
      duration_minutes: payload[:duration_minutes],
    )
    note.save!
    job.touch_activity!

    # Stamped back onto the email so the context section can say this one is
    # already on the board. Without it the same mail keeps reading as
    # outstanding and gets offered again every time the board is looked at.
    email&.update!(job_triage: email.job_triage.merge(job_note_id: note.id))

    job.reload
    # A revision undoes to the note's previous attributes, not to nothing:
    # unticking must never take the mail itself off the board.
    summary = existing ? "put that note back as it was on #{job.company}" : "took that note back off #{job.company}"
    reverts = (
      if existing
        [{ op: "updated", model: "JobNote", id: note.id, before: before.stringify_keys, summary: summary }]
      else
        [{ op: "created", model: "JobNote", id: note.id, summary: summary }]
      end
    )
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
