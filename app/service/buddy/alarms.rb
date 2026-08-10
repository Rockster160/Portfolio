module Buddy
  # An alarm RINGS: it goes off out loud, pushes to their phone, and keeps
  # crying until somebody taps it. A reminder is a message you have to be
  # looking at; an alarm is the one you can't miss.
  #
  # Three ways to say when: a duration ("in 20 minutes"), a clock time ("6:30"),
  # or a CONDITION ("the next time the washer finishes"). All three end up in
  # the same place, because the ringing is not built here - Buddy's alarm loop
  # (byte/buddy/alarm.js) runs for as long as ANY Buddy timer is in the
  # fired-but-unconfirmed state. So an alarm IS a Buddy countdown; what makes it
  # an alarm rather than a timer is the flag on it, which is what
  # Buddy::Timers.on_fired reads to decide whether the thing that just went off
  # announces the condition it was set for or announces that time is up.
  #
  # Riding the timer stack rather than growing a second one means the push, the
  # away case, the acknowledge tap, pause/resume, cancel, the offline queue and
  # the server-authoritative firing all already work.
  module Alarms
    module_function

    # A condition alarm has no duration - it should ring the moment the trigger
    # trips. One second rather than zero because Buddy::Timers anchors a
    # countdown to when the person ASKED, so a zero would be a timer that was
    # already over before it existed.
    LEAD_SECONDS = 1

    FLAG = "alarm".freeze

    # Is this fired timer an alarm? Read straight off the row, so a clock alarm
    # and a condition alarm answer the same way with nothing to look up.
    def alarm?(timer)
      return false if timer.nil?

      timer.metadata.to_h[FLAG].present?
    end

    # ---- setting one ---------------------------------------------------------

    # Ring at a wall-clock moment. The countdown is measured from the same
    # anchor Buddy::Timers uses (the message that asked), NOT from now — a
    # turn that takes four seconds would otherwise ring four seconds early,
    # which is the one error an alarm at a stated time must not have.
    def at!(user:, fire_at:, label:, conversation: nil)
      create!(user: user, seconds: seconds_until(fire_at, conversation), label: label, conversation: conversation)
    end

    # Ring after a stretch of time.
    def in!(user:, seconds:, label:, conversation: nil)
      create!(user: user, seconds: seconds, label: label, conversation: conversation)
    end

    # Ring now, because a watch just tripped.
    def ring!(watch)
      create!(
        user:         watch.user,
        seconds:      LEAD_SECONDS,
        label:        watch.body.to_s.strip.presence,
        conversation: watch.byte_conversation,
      )
    end

    def create!(user:, seconds:, label:, conversation: nil)
      Buddy::Timers.create!(
        user:         user,
        seconds:      seconds,
        label:        label,
        conversation: conversation,
        metadata:     { FLAG => true },
      )
    end

    # How long from the anchor to the moment they named. Returned unclamped so
    # the caller can tell "already gone" and "further off than a countdown
    # reaches" apart — Buddy::Timers would clamp both into something that rings
    # at the wrong time, silently.
    def seconds_until(fire_at, conversation=nil)
      (fire_at - Buddy::Timers.anchor_time(conversation)).round
    end

    # Whether a moment is one an alarm can actually be set for. Nil when it's
    # fine; otherwise the reason, phrased for the person.
    #
    # The ceiling is the timer stack's own 24 hours. Refusing rather than
    # stretching: past that, what they want is a reminder on a date, and an
    # alarm quietly rescheduled to a day earlier is worse than being told no.
    def out_of_reach(fire_at)
      return "that time has already gone" if fire_at.nil? || fire_at <= Time.current
      return nil if fire_at <= Buddy::Timers::MAX_SECONDS.seconds.from_now

      "an alarm only reaches 24 hours out - that far ahead wants schedule_reminder"
    end

    # ---- going off -----------------------------------------------------------

    # What it says in the thread and on the lock screen. Deliberately the thing
    # rather than the mechanism: "Washer's done" is what they set, and naming
    # the mechanism is what produced "your Washer's done timer's done".
    def fired_text(timer)
      said = timer.name.to_s.strip
      said.present? ? "⏰ #{said}" : "⏰ Alarm!"
    end

    def fired_title(timer)
      timer.name.to_s.strip.presence || "Alarm"
    end
  end
end
