Buddy::Tools.register(
  name:        :add_job_application,
  feature:     :job_search,
  description: <<~TXT,
    Start tracking a company that isn't on their board yet, with the first beat
    already on it. This is the one to reach for when mail arrives from somewhere
    with no row — a recruiter's first approach, or an application they made
    without saying so.

    Check the `job_search` context section first. If the same JOB is already
    there, even settled, this is the WRONG tool: use add_job_note, which hangs
    the beat off the row that exists.

    **A different role at a company they have already applied to IS a separate
    application** - three jobs at one place is three rows with three separate
    outcomes - so this is the right tool for that, and `role` is what tells the
    two apart. Passing no `role` for a company already on the board is refused,
    because then nothing can.

    `note` and `tag` work exactly as they do on add_job_note - the words of what
    happened, and what kind of beat it was. `occurred_at` is when it happened,
    which for mail is when the mail came in rather than now.

    `source` is where the application came from if it's known (LinkedIn, their
    careers page, a recruiter's name); `url` is the listing.

    `summary` is one line saying what the note SAYS, and it exists so `note`
    never has to be shortened. It is what the card shows them; `note` is what
    gets kept. Nothing stores it.
  TXT
  args:        {
    company:          { type: :string, required: true, description: "The company, as they'd say it" },
    role:             { type: :string, required: false, description: "The job title, if the mail names one" },
    note:             { type: :string, required: false, description: "What happened, in the mail's own words" },
    summary:          { type: :string, required: false, description: "One line of what `note` says, for the card only. Never stored" },
    tag:              {
      type:        :enum,
      required:    false,
      default:     :note,
      values:      JobNote.tags.keys.map(&:to_sym),
      description: "The kind of beat this first one was. An ATS receipt is `acknowledged`; an ask for times is `availability`",
    },
    occurred_at:      { type: :iso_time, required: false, description: "When it happened, if not now" },
    source:           { type: :string, required: false, description: "Where it came from - LinkedIn, a recruiter" },
    url:              { type: :string, required: false, description: "The listing, if there is one" },
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
    company = payload[:company].to_s.strip
    raise "which company?" if company.empty?

    # A DIFFERENT role at a company already on the board is a SEPARATE
    # application - three Aledade jobs in one day, three separate outcomes - and
    # opening it is what this branch is for. What is refused is the same job
    # twice, because a second row for one job splits its timeline and nothing
    # downstream would ever put the halves back together.
    existing = Buddy::JobHunt.applications_for(ctx.user, company)
    role     = payload[:role].to_s.strip

    if existing.any?
      # Nothing to tell them apart by. Refused rather than guessed: a row with
      # no role is the ordinary shape on this board, and half of what is on it
      # has none.
      if role.empty?
        raise "#{existing.first.company} is already on the board - if this is a different " \
              "job there, pass its `role`; if it is the same one, use add_job_note"
      end

      blank = existing.find { |job| job.role.blank? }
      if blank
        raise "#{blank.company} is on the board with no role recorded, so the two cannot be " \
              "told apart - use add_job_note if this is that same job"
      end

      # WHOLE_ROLE, not the looser SAME_ROLE the mail-matching uses: asking "is
      # this the same JOB" is the direction where a partial overlap lies.
      # "Staff Frontend Engineer" and "Principal Engineer" share the word
      # engineer, and at half a role that is enough to refuse a second job at a
      # company they have applied to twice — which is the whole of what this is
      # meant to allow.
      twin = existing.find { |job|
        Buddy::JobHunt.role_named_in?(job, role, ratio: Buddy::JobHunt::WHOLE_ROLE)
      }
      raise "#{twin.company} - #{twin.role} is already on the board - use add_job_note" if twin
    end

    tag  = payload[:tag].presence || :note
    body = payload[:note].to_s.strip
    raise "nothing to log - say what happened" if body.empty? && tag.to_s == "note"

    # Same rule add_job_note enforces, and for the same reason: a `scheduled`
    # note with no time puts nothing on the calendar, so the row claims an
    # interview and the day it is on stays empty.
    if tag.to_s == "scheduled" && payload[:follow_up_at].blank?
      raise "a scheduled interview needs its time - pass follow_up_at, or use a different tag"
    end

    {
      summary:  "Start tracking **#{company}**?",
      resolved: {
        company:          company,
        role:             payload[:role].presence,
        note:             body,
        summary:          payload[:summary].presence,
        tag:              tag,
        occurred_at:      payload[:occurred_at],
        source:           payload[:source].presence,
        url:              payload[:url].presence,
        spoke_to:         payload[:spoke_to].presence,
        follow_up_at:     payload[:follow_up_at],
        duration_minutes: payload[:duration_minutes],
      },
    }
  },
  # `summary` wins over `note` on the CARD and nowhere else — see add_job_note
  # for why the first seventy characters of a kept message are the wrong seventy.
  label:       ->(payload, _ctx) {
    label = JobNote::TAG_LABELS[payload[:tag].to_s] || "Note"
    gist  = payload[:summary].presence || payload[:note]
    sub   = [payload[:role].presence, "#{label} — #{gist.to_s.truncate(70)}"].compact
    { title: "💼 Track #{payload[:company]}", sub: sub.join("\n").presence }
  },
  merge_key:   ->(payload) { "add_job_application:#{payload[:company].to_s.downcase.strip}" },
  # Level 3, same as add_job_note: a whole new row on the board is more than a
  # beat on one, so it waits to be tapped rather than arriving pre-checked.
  level:       3,
  # One particular company on one particular day. Replaying it next month would
  # make a duplicate of something that is by then already there.
  routinable:  false,
  execute:     ->(payload, ctx) {
    # THE CHECK RUNS AGAIN HERE, and that is the whole point of it being here.
    #
    # `confirm:` is PROPOSAL time. Everything it establishes can stop being true
    # before the card is tapped, and for this tool it reliably does: a
    # confirmation mail arrives, the card is built against a clean board, and by
    # the time it is pressed jobhunt has written the row itself.
    #
    # JPMorganChase made two rows twelve seconds apart that way. Epicor made two
    # FOUR seconds apart - jobhunt recorded it at 21:20:58 and the Workday
    # acknowledgement opened a second at 21:21:02. Both times the card was
    # honestly clean when it was offered and made a duplicate when it was
    # pressed.
    #
    # Landing on the row that is already there is better than refusing: the mail
    # is worth keeping either way, and a beat on the right timeline is exactly
    # what it should have been.
    role  = payload[:role].to_s.strip
    twin  = Buddy::JobHunt.applications_for(ctx.user, payload[:company]).find { |row|
      role.present? && Buddy::JobHunt.role_named_in?(row, role, ratio: Buddy::JobHunt::WHOLE_ROLE)
    }

    job = twin || ctx.user.job_applications.create!(
      company: payload[:company],
      role:    payload[:role].presence,
      source:  payload[:source].presence,
      url:     payload[:url].presence,
    )

    note = nil
    if payload[:note].present? || payload[:tag].to_s != "note"
      note = job.notes.create!(
        body:             payload[:note].presence,
        tag:              payload[:tag],
        occurred_at:      payload[:occurred_at] || Time.current,
        source:           payload[:source].presence,
        spoke_to:         payload[:spoke_to].presence,
        follow_up_at:     payload[:follow_up_at],
        duration_minutes: payload[:duration_minutes],
      )
      job.touch_activity!
    end

    job.reload
    {
      company: job.company,
      status:  job.status,
      joined:  twin.present?,
      url:     "#{Buddy::AppPages.url_for("/interviews")}/#{job.id}",
      # Undoing has to take back only what was made. On a row that already
      # existed that is the NOTE - destroying the row would take the whole
      # history with it, including the beats that were there before this ran.
      reverts: (
        if twin
          note ? [{ op: "created", model: "JobNote", id: note.id,
                    summary: "removed that beat from #{job.company}" }] : []
        else
          # The note rides on `dependent: :destroy`, so undoing the row takes
          # its first beat with it and there is nothing left half-made.
          [{ op: "created", model: "JobApplication", id: job.id,
             summary: "stopped tracking #{job.company}" }]
        end
      ),
    }
  },
  receipt:     ->(result, _ctx) {
    "Tracking [#{result[:company]}](#{result[:url]}) ✓"
  },
)
