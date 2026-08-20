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

    # A ring asked for RIGHT NOW, which has already announced itself in the
    # thread before the countdown underneath it reaches zero. Buddy::Timers
    # reads this to know there is nothing left to say when it fires.
    QUICK = "quick".freeze

    # Is this fired timer an alarm? Read straight off the row, so a clock alarm
    # and a condition alarm answer the same way with nothing to look up.
    def alarm?(timer)
      return false if timer.nil?

      timer.metadata.to_h[FLAG].present?
    end

    def quick?(timer)
      return false if timer.nil?

      timer.metadata.to_h[QUICK].present?
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
      now!(
        user:         watch.user,
        conversation: watch.byte_conversation,
        label:        watch.body.to_s.strip.presence,
      )
    end

    # Ring now, full stop. LEAD_SECONDS rather than zero for the reason above:
    # Buddy::Timers anchors a countdown to when the person ASKED, so a zero is a
    # timer that was already over before it existed.
    def now!(user:, conversation:, label: nil, metadata: {})
      create!(user: user, seconds: LEAD_SECONDS, label: label, conversation: conversation, metadata: metadata)
    end

    # ---- the bare word -------------------------------------------------------

    # "alarm", and nothing else.
    #
    # Deliberately the whole message. Anything with more in it has a WHEN or a
    # WHAT in it — "alarm in 20 minutes", "alarm at 7", "set an alarm for the
    # washer" — and each of those is a different alarm that must not go off in
    # the room the moment it's typed. There is no ambiguity left to resolve in
    # the single word, which is exactly why it needn't cost a model turn.
    BARE_RX = /\A\s*alarm[\s.!]*\z/i

    def bare_request?(body)
      body.to_s.match?(BARE_RX)
    end

    # Straight from Rails, no model turn, same reasoning as the timer fast path
    # next door: a round trip costs several seconds, and they are several
    # seconds during which the model might not call the tool at all. On a
    # countdown that's most of a short timer; on this it's the whole point.
    # The chip is the WHOLE record of a bare ring, which is why it goes out
    # through CompanionDelivery rather than being written here: that is what
    # carries the push, and the push is how this reaches somebody who isn't
    # looking at the app. `quick_ring!` used to post the chip itself and leave
    # the notifying to the message Buddy::Timers.on_fired writes a second later
    # — so a single "alarm" produced two lines saying the same nothing, and
    # dropping the second one would have taken the only push with it.
    def quick_ring!(user, conversation)
      timer = now!(user: user, conversation: conversation, label: "Alarm", metadata: { QUICK => true })

      Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: conversation,
        text:         "#{conversation.buddy_name} sounded the alarm ⏰",
        metadata:     {
          "kind"      => "buddy_activity",
          "tool_name" => "alarm",
          "ok"        => true,
          "source"    => "fast_path",
          "timer_id"  => timer.id,
        },
        push_title:   "⏰ Alarm",
      )
    rescue StandardError => e
      Buddy::Errors.report(section: "alarms.quick_ring", exception: e, user: user)
      nil
    end

    def create!(user:, seconds:, label:, conversation: nil, metadata: {})
      Buddy::Timers.create!(
        user:         user,
        seconds:      seconds,
        label:        label,
        conversation: conversation,
        metadata:     { FLAG => true }.merge(metadata.to_h.stringify_keys),
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
