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

    **Times already SENT are not an ask.** An availability confirmation - thanks
    for your availability, here are the windows you picked, we will follow up
    with a final time - is the receipt for a job they have finished, and the next
    move is the company's. That is `note`. `availability` on it reprints a
    completed task at the top of their board and leaves it there, which is worse
    than no beat at all: the strip exists to say what is outstanding.

    **`interview` is the conversation HAPPENING, and nothing else.** It means
    they sat down and talked to a person. Mail is NEVER an `interview` beat: a
    mail can book one (`scheduled`), ask for their times (`availability`), call
    one off (`cancelled`), or follow one up (`heard_back`) - it is not the thing
    itself. The subject line is the trap. "Interview with Acme" is an INVITATION,
    and Neighbor's technical video interview was filed as `interview` off exactly
    that: it put a conversation on the timeline that had not happened, and
    because `interview` books nothing, the interview that WAS being arranged
    never reached the calendar. `recruiter_call` is the same rule for a call that
    actually took place.

    **A booking called off is `cancelled`, and that is the whole of it.** It is
    `scheduled` undone: filing it takes the meeting off their calendar, which is
    the thing that stops being true. Do NOT reach for `scheduled` again - that
    tag BOOKS, so it would put the cancelled interview back. `withdrew` is them
    pulling out, `rejected` is the application being over, and a round falling
    through is neither; if the mail says both, those are two beats and the
    cancellation is the smaller one. No date belongs on it - the date that
    mattered was on the booking it cancels.

    **An ATS receipt is `acknowledged`, not `applied` and not `heard_back`.**
    "Thanks for applying, a real human will review this" is a machine saying it
    arrived. `applied` is a thing THEY did, so putting it on a robot's reply
    says they applied twice; `heard_back` means a PERSON wrote, which is the
    beat actually being waited on, and a robot wearing it makes a live
    application look answered.

    **Coming from an ATS does not make a mail a receipt.** `acknowledged` is the
    application ARRIVING and nothing else, and logging it also moves the
    `applied` beat to sit just before the earliest one - so a mail that is only
    the robot doing paperwork rewrites when they applied. A code to verify an
    email address, a link to finish setting up a candidate account, a sign-in
    prompt, a password reset, a job-alert digest, a survey, a reminder about
    something already booked: same sender, no beat on the application. Those are
    `note`.

    **`note` is a correct answer, not a failure to classify.** It means "this
    happened", which is the honest record of mail that is none of the beats
    above. Picking the nearest-looking tag instead puts something on the
    timeline that is not true of the application, and the tags that look nearest
    are the ones that do the most: `acknowledged` moves the clock, `scheduled`
    books, and three of them close the application outright.

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
      description: "The kind of beat, and `note` whenever it is none of them. An application RECEIPT is `acknowledged` - other ATS mail is not; an ask for times is `availability`, not `scheduled`; a booking called off is `cancelled`, never `scheduled` again. offer/rejected/withdrew also settle the application",
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

    # The other half of the same mistake, and the more expensive one. An
    # `interview` beat is the conversation having happened, so a time on it or a
    # date ahead of now means the BOOKING is what is being described - and a
    # booking filed as `interview` writes nothing to the calendar, because only
    # `scheduled` syncs. Neighbor's technical video interview went on the board
    # that way and onto no agenda at all.
    if tag.to_s == "interview"
      if at.present?
        raise "an `interview` beat is the conversation happening, so it takes no " \
              "follow_up_at - `scheduled` is what books one and puts it on the calendar"
      end
      when_it_happened = payload[:occurred_at]
      if when_it_happened.present? && when_it_happened > Time.current
        raise "that interview is still ahead, so it has not happened yet - use `scheduled` " \
              "with the time, or `availability` if they are only asking for times"
      end
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
  # The line under the row. The whole point of it is the LINK: deciding whether
  # a mail really is a rejection means reading the mail, and before this the
  # only way there was to leave the thread and go hunting for it in the inbox.
  #
  # `label`'s sublabel cannot carry this - it is set with textContent, on
  # purpose, because it holds the sender's own words. The hint line is the one
  # slot that renders markdown, and a click inside it opens rather than ticking
  # (see linkifyWithoutTicking) - which matters here more than anywhere, since
  # the row IS a label and a stray tick files a beat on somebody's history.
  # NEVER NIL. A card that has nothing to open is a card that cannot be answered,
  # and this returned nil for every beat with no email on it.
  #
  # Neighbor, 5 Oct: "Neighbor has a technical video interview scheduled for the
  # Software Engineer role", then a row reading "💼 Interview — Neighbor" and the
  # same sentence under it. The receipt is the other link-bearing slot and it
  # only exists AFTER the tap, so a pending row leans entirely on this one - and
  # the mail had arrived as a `.partial.emlx` the watcher's glob could not see,
  # so there was no Email row and no `email_id`. His words: "no link to the
  # email, Ardesian page, job page, or anything. Quite unhelpful. I can't confirm
  # something that doesn't have any usable information."
  #
  # The ROW was never the missing part. `confirm:` resolves the application
  # before the card is ever drawn and puts `job_id` in the payload, so the one
  # thing a beat always has is the application it is about. The mail is the
  # better link when there is one, because reading it is what decides the tag;
  # the row is what there is otherwise, and it is the page the beat is going to
  # land on either way.
  hint:        ->(payload, ctx) {
    email = (ctx.user.emails.find_by(id: payload[:email_id]) if payload[:email_id].present?)
    row   = ("#{Buddy::AppPages.url_for("/interviews")}/#{payload[:job_id]}" if payload[:job_id].present?)

    if email.nil?
      # No mail to read, so the question is only whether this beat belongs on
      # that row - which means the row is the thing to open. `done` says nothing:
      # the receipt beside it already names and links the row, and repeating it
      # is the duplication REMOVAL_TOOLS exists to avoid.
      next nil if row.nil?

      { "tap" => "[#{payload[:company]} on the board](#{row}) - tapping files this beat on it" }
    else
      url = Rails.application.routes.url_helpers.email_url(id: email.id)
      # BOTH LINKS, because they answer different questions. The mail is what
      # decides the tag, so it leads; the row is what the beat lands on, and a
      # booking is the case where the mail has already settled the tag and the
      # only thing left to look at is the application it belongs to. A
      # `scheduled` card carried a time, a company and nowhere to go.
      board = (" or [#{payload[:company]} on the board](#{row})" if row.present?)
      {
        "tap"  => "[Read the email](#{url})#{board} - tapping files this beat and labels the mail",
        # The receipt beside this one names the board row and links it, so this
        # keeps the MAIL reachable. See add_job_application's for why both.
        "done" => "[The mail](#{url}) is tagged for you to clear - untick to take the note back",
      }
    end
  },
  # The same beat said twice in one turn is one beat.
  #
  # A booking is the exception and is keyed on the JOB instead of on the words,
  # because a job has one next interview and a reschedule IS that booking at a
  # new time. Three have arrived as a correcting mail behind the first and every
  # one left two cards up for one interview: iCapital on 21 Sep (Sep 24 1pm,
  # then "Please disregarded the last email" two minutes later) and again on
  # 1 Oct (Oct 5 9am, then "Please ignore the last confirmation" at 3:07pm), and
  # KODE Health on 25 Sep. Two of them put the cancelled slot on the calendar -
  # agenda items 1159 and 1174, both deleted by hand afterwards - and the 1 Oct
  # one left an Oct 5 card tappable with the interview moved to Oct 7.
  #
  # The words cannot be the key here: a reschedule arrives as a DIFFERENT mail
  # saying a different time, which is the whole point of it.
  merge_key:   ->(payload) {
    if payload[:tag].to_s == "scheduled" && payload[:job_id].present?
      "add_job_note:scheduled:job:#{payload[:job_id]}"
    else
      "add_job_note:#{payload[:company]}:#{payload[:tag]}:#{payload[:note].to_s.downcase.strip}"
    end
  },
  # Only the UNTAPPED card, never a filed one: the note and the calendar entry a
  # tap already wrote are a record this does not own, and that row's untick is
  # the only way back. It also makes a genuine second round safe, because one
  # arrives weeks later - long after the first card was answered - where a
  # correction arrives while the first is still sitting there unanswered.
  supersedes:  :pending,
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

    # Confirming the beat is the moment the mail stops being inbox - everything
    # it had to say is now on the board, which is where it will be looked for.
    #
    # Two halves, because an `Email` here is a COPY. This one is Ardesian's, and
    # is the whole job for domain mail. Mail mirrored in from Gmail is NOT
    # archived for him: Mail.app cannot remove a Gmail inbox label, so
    # LabelMailWorker tags it instead and he clears it himself. It deliberately
    # does not mark it read either - read and still in the inbox is the one
    # state worse than untouched.
    mail_before = email&.slice(:read_at, :archived_at)
    if email && !(email.read? && email.archived?)
      now = Time.current
      email.update!(read_at: email.read_at || now, archived_at: email.archived_at || now)
      LabelMailWorker.perform_async(email.id)
    end

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

    # Only Ardesian's copy comes back: unticking is a correction about the
    # BOARD, and a mail that has already synced its way out of the inbox is not
    # worth a second AppleScript round trip to reverse. Said plainly in the
    # row's own `done` hint rather than implied.
    if mail_before.present? && mail_before.values.any?(&:nil?)
      reverts << {
        op:      "updated",
        model:   "Email",
        id:      email.id,
        before:  mail_before.stringify_keys,
        summary: "put that mail back in the inbox",
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
