module Buddy
  # The mini-alert in Byte for an application whose next move is HIS.
  #
  # The board paints this at the top of the interviews page, and that page was
  # the only place it was ever visible. Byte is where the day is actually read,
  # so an availability request or a take-home could sit for days and only be
  # found by somebody going to look for it.
  #
  # An alert rather than a message because this is a CONDITION: it is true until
  # he does the thing, and a second message tomorrow saying the same thing helps
  # nobody. One bubble carries it, the pinned strip keeps it from being scrolled
  # past, and it rewrites itself into the record that it was handled.
  #
  # ONE ALERT PER APPLICATION, because they clear separately - answering an
  # offer at one company says nothing about the availability another is waiting
  # on. The key is therefore stable per row, so a second beat of his to answer
  # rewrites the bubble that row already owns instead of stacking a second.
  module JobWaiting
    module_function

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
      # No body on the resolve: the bubble keeps the words it opened with and
      # simply stops reading as outstanding, which is the honest record - what
      # was owed is still what was owed.
      return ::Buddy::Alerts.resolve!(user: job.user, key: key_for(job.id)) if note.nil?

      ::Buddy::Alerts.raise!(user: job.user, key: key_for(job.id), body: body_for(job, note))
    end

    def waiting_note(job)
      ::JobNote.waiting_on_you_for(job.user).find_by(job_application_id: job.id)
    end

    # The same shape as the row this beat puts on the calendar - what is owed,
    # then which job. The link is most of the reason to have it in Byte at all:
    # the strip prints a link's text and the bubble is one tap from the timeline.
    def body_for(job, note)
      "#{note.owed}: [#{job.label}](#{job.interview_url})"
    end
  end
end
