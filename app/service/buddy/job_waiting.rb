module Buddy
  # The chip on Buddy's strip for an application whose next move is HIS.
  #
  # The board paints this at the top of the interviews page, and that page was
  # the only place it was ever visible. Byte is where the day is read, so an
  # availability request or a take-home could sit for days and only be found by
  # somebody going to look for it.
  #
  # A CHIP rather than an alert, and the difference is how much of the screen it
  # is allowed: an alert owns a bubble in the thread and a bar across the foot of
  # the hero, which is the right weight for a house-level condition and far too
  # much for one of a dozen applications. A chip is one line over Buddy's
  # shoulder, `state: :waiting` is the state the strip already colours as
  # "asking for a person" and sorts to the front, and a waiting chip is exempt
  # from ageing out - so it sits there until the thing is done.
  #
  # ONE CHIP PER APPLICATION, keyed `job:waiting:<id>`, because they clear
  # separately: answering an offer at one company says nothing about the
  # availability another is waiting on. A stable key also means a second beat of
  # his rewrites that row's chip rather than adding one.
  module JobWaiting
    module_function

    # Lowercase with colons for nesting, which is what BackgroundProcess::KEY_RX
    # allows - the key travels in a URL path.
    def key_for(job_application_id)
      "job:waiting:#{job_application_id}"
    end

    # Raise it, clear it, or do neither. Read back through
    # `JobNote.waiting_on_you_for` - the same scope the board's strip draws
    # from - so the two can never disagree about what is outstanding.
    #
    # Takes an ID because this runs from a note's `after_commit`, destroy
    # included, and the application can be gone by then.
    def sync!(job_application_id)
      job = ::JobApplication.find_by(id: job_application_id)
      return nil if job.nil?

      note = waiting_note(job)
      # Cleared, not settled. A chip reporting `finished` stays on the strip
      # saying what became of it, and there is no outcome to show here - the
      # beat that moved the ball is on the timeline where history goes.
      return ::BackgroundProcess.clear(user: job.user, key: key_for(job.id)) if note.nil?

      chip!(job, note)
    end

    # The name is the WHOLE chip and gets 20 characters, so it carries what is
    # owed - all four of `JobNote::BALL_IN_COURT` fit - and the company rides on
    # the link pill underneath, which is also where a tap goes. Two companies
    # owing availability are then two chips reading the same thing and labelled
    # apart, which is the right way round: the verb is what he is scanning for.
    def chip!(job, note)
      ::BackgroundProcess.note(
        user:   job.user,
        key:    key_for(job.id),
        name:   note.owed,
        state:  :waiting,
        detail: job.label,
        links:  [{ label: job.company, url: job.interview_url }],
        source: :interviews,
      )
    end

    def waiting_note(job)
      ::JobNote.waiting_on_you_for(job.user).find_by(job_application_id: job.id)
    end
  end
end
