# Dates on the interview tracker. Everything here is either an appointment or
# something owed by a date, so it's read to plan around — which means the
# weekday is the part that matters. "Sep 7" needs a calendar lookup before it
# means anything; "Monday, Sep 7" is already the answer.
module JobApplicationsHelper
  def interview_day(time, at_time: true)
    return nil if time.blank?

    time.strftime(at_time ? "%A, %b %-d at %-I:%M %p" : "%A, %b %-d")
  end
end
