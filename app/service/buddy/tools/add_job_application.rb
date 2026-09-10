Buddy::Tools.register(
  name:        :add_job_application,
  feature:     :job_search,
  description: <<~TXT,
    Start tracking a company that isn't on their board yet, with the first beat
    already on it. This is the one to reach for when mail arrives from somewhere
    with no row — a recruiter's first approach, or an application they made
    without saying so.

    Check the `job_search` context section first. If the company IS already
    there, even settled, this is the WRONG tool: use add_job_note, which hangs
    the beat off the row that exists. Two rows for one company is the mess this
    is most likely to make.

    `note` and `tag` work exactly as they do on add_job_note - the words of what
    happened, and what kind of beat it was. `occurred_at` is when it happened,
    which for mail is when the mail came in rather than now.

    `source` is where the application came from if it's known (LinkedIn, their
    careers page, a recruiter's name); `url` is the listing.
  TXT
  args:        {
    company:      { type: :string, required: true, description: "The company, as they'd say it" },
    role:         { type: :string, required: false, description: "The job title, if the mail names one" },
    note:         { type: :string, required: false, description: "What happened, in the mail's own words" },
    tag:          {
      type:        :enum,
      required:    false,
      default:     :note,
      values:      JobNote.tags.keys.map(&:to_sym),
      description: "The kind of beat this first one was",
    },
    occurred_at:  { type: :iso_time, required: false, description: "When it happened, if not now" },
    source:       { type: :string, required: false, description: "Where it came from - LinkedIn, a recruiter" },
    url:          { type: :string, required: false, description: "The listing, if there is one" },
    spoke_to:     { type: :string, required: false, description: "Who they dealt with, if a person was named" },
    follow_up_at: { type: :iso_time, required: false, description: "Only if they said they'd chase it" },
  },
  confirm:     ->(payload, ctx) {
    company = payload[:company].to_s.strip
    raise "which company?" if company.empty?

    # The guard the description asks for, enforced rather than trusted. A second
    # row for a company already on the board splits its timeline in two, and
    # nothing downstream would ever put them back together.
    existing = Buddy::JobHunt.resolve_application(ctx.user, company)
    raise "#{existing.company} is already on the board - use add_job_note" if existing

    tag  = payload[:tag].presence || :note
    body = payload[:note].to_s.strip
    raise "nothing to log - say what happened" if body.empty? && tag.to_s == "note"

    {
      summary:  "Start tracking **#{company}**?",
      resolved: {
        company:      company,
        role:         payload[:role].presence,
        note:         body,
        tag:          tag,
        occurred_at:  payload[:occurred_at],
        source:       payload[:source].presence,
        url:          payload[:url].presence,
        spoke_to:     payload[:spoke_to].presence,
        follow_up_at: payload[:follow_up_at],
      },
    }
  },
  label:       ->(payload, _ctx) {
    label = JobNote::TAG_LABELS[payload[:tag].to_s] || "Note"
    sub   = [payload[:role].presence, "#{label} — #{payload[:note].to_s.truncate(70)}"].compact
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
    job = ctx.user.job_applications.create!(
      company: payload[:company],
      role:    payload[:role].presence,
      source:  payload[:source].presence,
      url:     payload[:url].presence,
    )

    if payload[:note].present? || payload[:tag].to_s != "note"
      job.notes.create!(
        body:         payload[:note].presence,
        tag:          payload[:tag],
        occurred_at:  payload[:occurred_at] || Time.current,
        source:       payload[:source].presence,
        spoke_to:     payload[:spoke_to].presence,
        follow_up_at: payload[:follow_up_at],
      )
      job.touch_activity!
    end

    job.reload
    {
      company: job.company,
      status:  job.status,
      url:     "#{Buddy::AppPages.url_for("/interviews")}/#{job.id}",
      # The note rides on `dependent: :destroy`, so undoing the row takes its
      # first beat with it and there is nothing left half-made.
      reverts: [{
        op:      "created",
        model:   "JobApplication",
        id:      job.id,
        summary: "stopped tracking #{job.company}",
      }],
    }
  },
  receipt:     ->(result, _ctx) {
    "Tracking [#{result[:company]}](#{result[:url]}) ✓"
  },
)
