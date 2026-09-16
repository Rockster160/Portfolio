module Buddy
  # The job search, as Buddy sees it: the board, and the mail that has come in
  # about them.
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
    # and add_job_note resolving what the model named.
    #
    # EVERY application, settled ones included. It was live-only, on the
    # reasoning that a beat on a job closed months ago is nearly always a
    # misfire - and the cost of that showed up as prod 5759. Rocco said
    # "Corporate Tools rejected me"; Corporate Tools was already closed, so it
    # wasn't on the board the model could see and it wasn't resolvable either.
    # With no way to be right and no way to say so, the model reached for the
    # nearest live company and settled the wrong one.
    #
    # A closed application is still a thing that happened to them and still a
    # thing they talk about. Being unable to see it doesn't stop the sentence
    # arriving - it just removes the correct answer.
    def resolve_application(user, company)
      name = company.to_s.strip
      return nil if name.empty?

      board = JobApplication.where(user: user)
      hit   = JobSearch.call(board, normalize(name)).first
      return hit if hit

      # Still nothing: try the leading word on its own, for the "Netflix Talent
      # Acquisition" shape where the extra words are a department rather than
      # part of the name. Accepted ONLY when it is unambiguous - one head word
      # matching two applications is a coin toss, and a note on the wrong
      # company is worse than no note.
      head = normalize(name).split.first
      return nil if head.blank?

      matches = JobSearch.call(board, head)
      matches.one? ? matches.first : nil
    end

    # Is THIS row's role the one the text is talking about?
    #
    # Containment on the normalized role, which is the safe direction: a role
    # that appears is a match, and anything else is "don't know" rather than
    # "no". Callers decide what to do with a no, and both of them treat it as a
    # reason to ask rather than a reason to act.
    #
    # Words of three letters or more, so "AI" and "I-" contribute nothing and a
    # one-letter suffix can't carry a match on its own. A role the row doesn't
    # have is unanswerable and returns false.
    # Enough of the role to say "this is that job". Half, because an ATS
    # headline abbreviates: "Application received for Principal Engineer"
    # against a row reading "Principal Engineer - AI Data and Infrastructure"
    # is the same job with the tail cut off, and refusing that would send a
    # correct note to a new application.
    SAME_ROLE = 0.5

    # ALL of it, for the other direction. Picking a row off the board with
    # nothing but a role to go on has no company to check against, so a partial
    # overlap is not enough - "Senior Backend Engineer" and "Senior Frontend
    # Engineer" share two words out of three.
    WHOLE_ROLE = 1.0

    def role_named_in?(job, text, ratio: SAME_ROLE)
      role = job.respond_to?(:role) ? job.role : nil
      words = role_words(role)
      return false if words.empty?

      said = role_words(text)
      return false if said.empty?

      (words & said).length >= (words.length * ratio)
    end

    # The board row whose ROLE the text names, when exactly one does.
    #
    # Prod 15 Sep, email 51716: a Greenhouse "thank you for applying" that
    # names a role and no company anywhere in it - the classifier had nothing
    # to put in `company` and was right not to guess. Twelve minutes later
    # jobhunt opened application 29, Fieldwire by Hilti, Senior Backend
    # Engineer, for that exact role. `resolve_application` takes a company and
    # only a company, so the receipt could not reach the board even with the row
    # sitting there, and 29 is the only application of the day with no
    # `acknowledged` beat on it.
    #
    # Unambiguous only, mirroring the head-word rule above: two applications
    # whose roles both appear is a coin toss, and a note on the wrong one is
    # worse than no note.
    def resolve_by_role(user, text)
      said = role_words(text)
      return nil if said.empty?

      matches = JobApplication.where(user: user).select { |job|
        role_named_in?(job, text, ratio: WHOLE_ROLE)
      }
      matches.one? ? matches.first : nil
    end

    # Through Flourish so the filler words go - "and", "for", "the" - and both
    # sides are normalized the same way. Without that, "Principal Engineer - AI
    # Data and Infrastructure" counts "and" as a word of the role, and any
    # headline with an "and" in it scores a point against it.
    def role_words(text)
      Buddy::Flourish.significant(text)
    end

    def normalize(name)
      words = name.to_s.downcase.gsub(/[^a-z0-9&\-\s]/, " ").split
      words.pop while words.length > 1 && LEGAL_SUFFIXES.include?(words.last)
      words.join(" ")
    end

    def context_for(user)
      return nil if user.nil?

      board = applications(user)
      mail  = recent_mail(user)
      return nil if board.empty? && mail.empty?

      {
        url:          "#{Buddy::AppPages.url_for("/interviews")}/{id}",
        about:        "Their job applications and the mail that has arrived about them. " \
                      "`status` says where each one stands - a settled one (rejected, " \
                      "closed, offer) is still here to be talked about and can still take " \
                      "a note. `url` takes an application's `id`. Log a beat with add_job_note.",
        applications: board,
        recent_mail:  mail,
      }
    end

    # The whole board. `status` rides on every row (see slim_application), so a
    # settled one reads as settled rather than as one more open lead - which is
    # the only thing hiding them was buying, and it cost the ability to talk
    # about them at all.
    #
    # Uncapped on purpose: a person's job hunt is tens of rows, not thousands,
    # and a cap here would silently drop the oldest - which is exactly the class
    # of row that has just been settled.
    def applications(user)
      scope = JobApplication.where(user: user).includes(:notes).ordered
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
