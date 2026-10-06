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
      description: "The kind of beat this first one was, and `note` whenever it is none of them. An application RECEIPT is `acknowledged` - other ATS mail is not; an ask for times is `availability`; a booking called off is `cancelled`",
    },
    email_id:         { type: :integer, required: false, description: "The email this came from, from recent_mail" },
    occurred_at:      { type: :iso_time, required: false, description: "When it happened, if no email_id carries the date" },
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
    # THE ROW THIS IS REALLY ABOUT, set when the company turns out to be on the
    # board after all. The board moves between a seed being built and a card
    # being proposed - jobhunt writes the row for the same mail, seconds apart -
    # and the beat belongs on that row either way.
    #
    # It is the same answer `execute` reaches on its own, and it must be: a
    # refusal here discards the whole proposal, and the only thing the person
    # sees for it is a reply that did not understand them. What the card SAYS
    # changes with it, from `Track` to the beat it files.
    onto = nil

    if existing.any?
      if role.empty?
        # Nothing to tell them apart by, and more than one to tell apart. A row
        # with no role is the ordinary shape on this board, so a guess between
        # several is a beat on the wrong timeline.
        if existing.many?
          raise "#{existing.first.company} is already on the board #{existing.size} times - " \
                "pass the `role` this mail is about, or use add_job_note on the right row"
        end

        onto = existing.first
      else
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
        # meant to allow. No twin means a new row, which is what this tool is for.
        onto = existing.find { |job|
          Buddy::JobHunt.role_named_in?(job, role, ratio: Buddy::JobHunt::WHOLE_ROLE)
        }
      end
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
      summary:  (
        if onto
          "Log **#{JobNote::TAG_LABELS[tag.to_s] || 'Note'}** on **#{onto.company}**?"
        else
          "Start tracking **#{company}**?"
        end
      ),
      resolved: {
        company:          company,
        # Only set when the board already holds this job. `execute` finds the row
        # again on its own - this is what lets the card, the hint and the receipt
        # say which of the two things is about to happen.
        job_id:           onto&.id,
        role:             payload[:role].presence,
        note:             body,
        summary:          payload[:summary].presence,
        tag:              tag,
        email_id:         payload[:email_id],
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
    # `Track` is a promise about the BOARD, and with `job_id` set there is already
    # a row - the beat is all that is new, so the card reads like add_job_note's.
    title = (
      if payload[:job_id].present?
        "💼 #{label} — #{payload[:company]}"
      else
        "💼 Track #{payload[:company]}"
      end
    )
    { title: title, sub: sub.join("\n").presence }
  },
  merge_key:   ->(payload) { "add_job_application:#{payload[:company].to_s.downcase.strip}" },
  # The mail this row is about, openable BEFORE the tap. Same reasoning as
  # add_job_note's: a card proposing to open an application off an email is
  # asking a question only the email can answer.
  hint:        ->(payload, ctx) {
    email = (ctx.user.emails.find_by(id: payload[:email_id]) if payload[:email_id].present?)
    row   = ("#{Buddy::AppPages.url_for("/interviews")}/#{payload[:job_id]}" if payload[:job_id].present?)

    if email.nil?
      # The row is there to look at when this is landing on one, which is the
      # same thing add_job_note offers and for the same reason: whether the beat
      # belongs on that row is the only question left.
      next { "tap" => "[#{payload[:company]} on the board](#{row}) - tapping files this beat on it" } if row
      # Nothing of this exists yet - no row, and no mail we kept - so the LISTING
      # is the only thing there is to look at, and whether this is worth tracking
      # is exactly the question it answers. Absent more often than not, and then
      # the card stands on its own: "Track <Company>" names the company and the
      # role, which is the whole of what a new row would hold.
      #
      # add_job_note's hint has the row to fall back on and must never be nil;
      # this one can be, because there is genuinely nowhere to go.
      next nil if payload[:url].blank?

      { "tap" => "[The listing](#{payload[:url]}) - tapping opens a row on the board for it" }
    else
      url = Rails.application.routes.url_helpers.email_url(id: email.id)
      {
        "tap"  => "[Read the email](#{url}) - tapping #{row ? 'files it on the board' : 'opens the row'} " \
                  "and labels the mail",
        # STILL A LINK AFTER THE TAP. This read "On the board, and the mail
        # tagged for you to clear", which repeated the receipt beside it and
        # offered nowhere to go - and a ticked row is exactly when there is
        # somewhere: the row this just made may be a duplicate that needs
        # merging. The receipt names the board row, so this one names the mail.
        "done" => "[The mail](#{url}) is tagged for you to clear - untick to take the row back",
      }
    end
  },
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
    #
    # With no role, it is the company alone. `confirm:` refuses that outright
    # when the company is already there, so a role-less card can only have been
    # offered against an empty board - and one row appearing since is the job
    # the mail was about - a card offered a minute before jobhunt opens the row
    # would otherwise add a second one beside it. More than one is a guess, and
    # refused.
    role  = payload[:role].to_s.strip
    rows  = Buddy::JobHunt.applications_for(ctx.user, payload[:company])
    twin  = (
      if role.present?
        rows.find { |row| Buddy::JobHunt.role_named_in?(row, role, ratio: Buddy::JobHunt::WHOLE_ROLE) }
      elsif rows.many?
        raise "#{rows.first.company} has #{rows.size} applications on the board now - " \
              "use add_job_note on the one this is about"
      else
        rows.first
      end
    )

    job = twin || ctx.user.job_applications.create!(
      company: payload[:company],
      role:    payload[:role].presence,
      source:  payload[:source].presence,
      url:     payload[:url].presence,
    )

    # The mail's own clock, sender and link, exactly as add_job_note stamps
    # them - the first beat on a new row is no less an email than the fifth on
    # an old one, and the two sit in the same timeline.
    email = (ctx.user.emails.find_by(id: payload[:email_id]) if payload[:email_id].present?)

    note = nil
    if payload[:note].present? || payload[:tag].to_s != "note"
      note = job.notes.create!(
        body:             payload[:note].presence,
        tag:              payload[:tag],
        occurred_at:      email&.timestamp || payload[:occurred_at] || Time.current,
        source:           (email ? "Email" : payload[:source].presence),
        url:              (email ? Rails.application.routes.url_helpers.email_url(id: email.id) : nil),
        spoke_to:         payload[:spoke_to].presence,
        follow_up_at:     payload[:follow_up_at],
        duration_minutes: payload[:duration_minutes],
      )
      job.touch_activity!
      # Without this the same mail keeps reading as outstanding and gets offered
      # again every time the board is looked at.
      email&.update!(job_triage: email.job_triage.merge(job_note_id: note.id))
    end

    # See add_job_note.
    mail_before = email&.slice(:read_at, :archived_at)
    if email && !(email.read? && email.archived?)
      now = Time.current
      email.update!(read_at: email.read_at || now, archived_at: email.archived_at || now)
      LabelMailWorker.perform_async(email.id)
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
      ) + (
        # Only Ardesian's copy comes back - a mail already synced out of the
        # inbox is not worth a second AppleScript round trip to reverse.
        if mail_before.present? && mail_before.values.any?(&:nil?)
          [{ op: "updated", model: "Email", id: email.id,
             before: mail_before.stringify_keys,
             summary: "put that mail back in the inbox" }]
        else
          []
        end
      ),
    }
  },
  receipt:     ->(result, _ctx) {
    return "Logged on [#{result[:company]}](#{result[:url]}) ✓" if result[:joined]

    "Tracking [#{result[:company]}](#{result[:url]}) ✓"
  },
)
