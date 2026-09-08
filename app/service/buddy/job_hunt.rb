module Buddy
  # The job search, as Buddy sees it: the board of live applications, and the
  # mail that has come in about them.
  #
  # Two halves that only make sense together. The applications are what a note
  # can be attached to, and the mail is what there is to say. Handing over one
  # without the other produces the two failures this is shaped to avoid - a
  # company named with nothing known to have happened, or a beat with nowhere
  # to put it.
  #
  # On demand via get_context, never prompt-resident. Most days nothing has
  # moved, and seventeen applications in every prompt is a page of context to
  # answer a question nobody asked.
  module JobHunt
    module_function

    # Enough to cover "did I hear back from anyone this week?" without turning
    # into the whole archive. The board itself is short by nature.
    MAIL_WINDOW = 30.days
    MAX_MAIL = 15

    # Legal suffixes, stripped only when they TRAIL the name. JobSearch requires
    # every token to land somewhere, which is right for a person typing into the
    # board's search box and wrong for a name lifted off an ATS footer: "CSC
    # Generation, Inc." arrives as three tokens, "inc." matches nothing, and the
    # whole query scores nil against the application it obviously means.
    #
    # Trailing only, because these words are ordinary inside a name - "Co-op
    # Group", "Limited Run Games" - and a blanket strip would eat half of one.
    LEGAL_SUFFIXES = %w[
      inc
      incorporated
      llc
      lp
      llp
      ltd
      limited
      corp
      corporation
      co
      plc
      gmbh
      ag
      sa
      nv
      bv
      pty
      holdings
    ].freeze

    # One place, because both callers get it wrong in the same way otherwise:
    # Emails::JobTriage matching a verdict's company to decide whether to offer,
    # and add_job_note resolving what the model named. Live applications only -
    # logging a beat on a job they closed months ago is nearly always a misfire.
    def resolve_application(user, company)
      name = company.to_s.strip
      return nil if name.empty?

      live = JobApplication.where(user: user).live
      hit  = JobSearch.call(live, normalize(name)).first
      return hit if hit

      # Still nothing: try the leading word on its own, for the "Netflix Talent
      # Acquisition" shape where the extra words are a department rather than
      # part of the name. Accepted ONLY when it is unambiguous - one head word
      # matching two applications is a coin toss, and a note on the wrong
      # company is worse than no note.
      head = normalize(name).split.first
      return nil if head.blank?

      matches = JobSearch.call(live, head)
      matches.one? ? matches.first : nil
    end

    def normalize(name)
      words = name.to_s.downcase.gsub(/[^a-z0-9&\-\s]/, " ").split
      words.pop while words.length > 1 && LEGAL_SUFFIXES.include?(words.last)
      words.join(" ")
    end

    def context_for(user)
      return nil if user.nil?

      applications = live_applications(user)
      mail = recent_mail(user)
      return nil if applications.empty? && mail.empty?

      {
        url:          "#{Buddy::AppPages.url_for("/interviews")}/{id}",
        about:        "Their job applications and the mail that has arrived about them. " \
                      "`url` takes an application's `id`. Log a beat with add_job_note.",
        applications: applications,
        recent_mail:  mail,
      }
    end

    # Live only - rejected and closed applications are history, and a note on
    # one is almost always a misfire. Anything genuinely about a settled
    # application still reaches the board through the page itself.
    def live_applications(user)
      scope = JobApplication.where(user: user).live.includes(:notes).ordered
      scope.map { |job| slim_application(job) }
    end

    def slim_application(job)
      latest = job.notes.max_by { |note| [note.occurred_at, note.id] }
      owed   = job.notes.filter_map(&:follow_up_at).min

      {
        id:        job.id,
        company:   job.company,
        role:      job.role.presence,
        status:    job.status,
        last_beat: (latest && "#{latest.tag_label} on #{latest.occurred_at.to_date.iso8601}"),
        notes:     job.notes.size,
        # The one field that is a question rather than a fact: a follow-up in
        # the past is something they owe somebody NOW.
        follow_up: owed&.to_date&.iso8601,
      }.compact
    end

    # Job mail from the last month, newest first. `logged` is what makes this
    # answerable rather than merely informative: it is the difference between
    # "Netflix wrote" and "Netflix wrote and it is already on the board".
    def recent_mail(user)
      scope = user.emails.job_mail.where(timestamp: MAIL_WINDOW.ago..).ordered
      scope.limit(MAX_MAIL).map { |email| slim_mail(email) }
    end

    def slim_mail(email)
      triage = email.job_triage

      {
        email_id: email.id,
        on:       email.timestamp.to_date.iso8601,
        from:     Emails::JobTriage.sender_line(email),
        subject:  email.subject,
        headline: triage[:headline],
        kind:     triage[:kind],
        company:  triage[:company],
        logged:   triage[:job_note_id].present?,
      }.compact
    end
  end
end
