module Buddy
  # One place that decides how a reminder READS: its glyph, its label, and the
  # line underneath saying when it goes off.
  #
  # Two surfaces show the same rows and can do different things with them. The
  # in-thread list Buddy posts when asked ("here's what you've got set") is a
  # snapshot you can strike a row off. The Reminders panel in the drawer is a
  # manager: it also shows the ones you've turned off, so switching one back on
  # is possible. What a row SAYS is identical in both, so it's decided here
  # rather than twice.
  #
  # Two record types share the list. A BuddyReminder fires at a time; a
  # BuddyWatch fires when something happens. From the person's side they're the
  # same promise, so they're one list with a glyph telling them apart.
  module ReminderPresenter
    module_function

    LIMIT = 50

    # Time-based first (soonest on top), then condition watches (oldest first).
    #
    # `include_off` is the whole difference between the two surfaces. In a
    # thread a cancelled reminder is gone and listing it would be noise; in the
    # manager it has to stay visible, or turning one off is a one-way door.
    def rows(user, include_off: false)
      reminder_rows(user, include_off) + watch_rows(user, include_off) + cycle_rows(user)
    end

    # A work/break rhythm. It isn't a reminder and it isn't a watch, but it's a
    # standing thing that will keep asking for their attention, which is what
    # this list is FOR — and until it was on here the only way to stop one was
    # to swipe a countdown away and hope.
    #
    # One row per rhythm, not per block: a cycle is a dozen timer rows over an
    # afternoon and the person thinks of it as one thing.
    def cycle_rows(user)
      Buddy::TimerCycle.live_cycles(user).map { |live|
        {
          type:       :cycle,
          record_id:  live[:id],
          glyph:      "⏲",
          label:      live[:cycle]["label"].to_s.presence || "Work rhythm",
          sublabel:   Buddy::TimerCycle.describe(user, live[:cycle]),
          enabled:    true,
          body:       live[:cycle]["label"].to_s,
          at:         nil,
          recurring:  true,
          listener:   nil,
          custom:     false,
          templated:  false,
          expires_on: nil,
        }
      }
    rescue StandardError => e
      Buddy::Errors.report(section: "reminder_presenter.cycle_rows", exception: e, user: user)
      []
    end

    def reminder_rows(user, include_off)
      scope = BuddyReminder.where(user_id: user.id, fired_at: nil)
      scope = scope.where(cancelled_at: nil) unless include_off
      scope.order(:fire_at).limit(LIMIT).map { |r|
        {
          type:       :reminder,
          record_id:  r.id,
          glyph:      reminder_glyph(r),
          label:      r.body.to_s.truncate(80),
          sublabel:   when_text(r, user),
          enabled:    r.cancelled_at.nil?,
          # The editor writes back into these, so they're the raw values rather
          # than the display ones - `label` is truncated and `sublabel` is
          # prose, and round-tripping either would quietly rewrite the reminder.
          body:       r.body.to_s,
          at:         edit_time(r, user),
          recurring:  r.recurring?,
          # Both row types carry the same keys so the editor reads one shape.
          listener:   nil,
          custom:     false,
          templated:  false,
          expires_on: nil,
        }.merge(recurrence_fields(r))
      }
    end

    # The repeat RULE, in the vocabulary the calendar has always used (see
    # Recurrence). A reminder used to carry four frequencies with no interval,
    # no nth-weekday and no end date, so "every second Tuesday" was something
    # the calendar could express and a reminder could not.
    #
    # Handed over already normalized, so a row still written in the old shape
    # edits as though it had always been in the new one.
    def recurrence_fields(reminder)
      return NO_RECURRENCE unless reminder.recurring?

      rule = reminder.rule
      {
        freq:         rule.freq.to_s,
        by_day:       rule.by_day,
        by_month_day: Array(reminder.normalized_recurrence["by_month_day"]).map(&:to_i),
        interval:     rule.interval,
        unit:         rule.unit.to_s,
        by_set_pos:   rule.set_pos,
        starts_on:    rule.starts_on&.iso8601,
        until_on:     rule.until_on&.iso8601,
      }
    end

    NO_RECURRENCE = {
      freq:         nil,
      by_day:       [],
      by_month_day: [],
      interval:     nil,
      unit:         nil,
      by_set_pos:   nil,
      starts_on:    nil,
      until_on:     nil,
    }.freeze

    # What the time field starts on. A recurrence only has an hour to move, so
    # it hands back "HH:MM" for a `time` input; a one-off hands back a whole
    # local datetime. The controller reads them apart the same way.
    def edit_time(reminder, user)
      if reminder.recurring?
        hour, minute = reminder.time_of_day
        return format("%<hour>02d:%<minute>02d", hour: hour, minute: minute)
      end

      reminder.fire_at&.in_time_zone(user.timezone)&.strftime("%Y-%m-%dT%H:%M")
    end

    # A reminder that RUNS something is a different animal from one that tells
    # you something, and until you see them side by side there's no way to know
    # which you set. The glyph is the whole tell, so it earns its place here in
    # a way one repeated on every line in the thread does not.
    def reminder_glyph(reminder)
      return "⚡" if reminder.command
      return "🔁" if reminder.recurring?

      "⏰"
    end

    def watch_rows(user, include_off)
      scope = BuddyWatch.where(user_id: user.id, fired_at: nil)
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
      # A `cancel` watch is the ENDING of a reminder, not a rule of its own. It
      # already shows on that reminder's row, and listed separately it's a
      # second thing to switch off — where switching off the stopper leaves the
      # repeat running with nothing left to end it.
      scope = scope.where.not(kind: :cancel)
      scope = scope.where(cancelled_at: nil) unless include_off
      scope.order(:created_at).limit(LIMIT).map { |w|
        {
          type:       :watch,
          record_id:  w.id,
          glyph:      watch_glyph(w.trigger_scope),
          label:      w.body.to_s.truncate(80),
          sublabel:   watch_when(w),
          enabled:    w.cancelled_at.nil?,
          body:       w.body.to_s,
          # A watch has no clock to move - it fires on a condition.
          at:         nil,
          recurring:  false,
          # The condition, when it's a hand-written one. A named trigger
          # (deploy, arriving somewhere, finishing a chore) was assembled from
          # structured pieces rather than written, so there's no line to hand
          # back and the editor shows it as read-only instead.
          listener:   w.listener.presence,
          custom:     w.custom?,
          # A repeating watch's body is a TEMPLATE (see Buddy::WatchMatcher),
          # so the editor can offer the placeholders. A one-shot goes through
          # the model, where the body is a brief rather than a line to print.
          templated:  !w.one_shot,
          # When it stops watching. A date rather than a timestamp: "only
          # today" is what people mean, and the sweeper reads end-of-day.
          expires_on: expiry_date(w, user)&.iso8601,
        }.merge(NO_RECURRENCE)
      }
    end

    # Find one back from the type + id a client hands us. Scoped to the user, so
    # an id belonging to someone else reads as absent rather than forbidden.
    def find(user, type, id)
      case type.to_s
      when "reminder" then BuddyReminder.where(user_id: user.id).find_by(id: id)
      when "watch"    then BuddyWatch.where(user_id: user.id).find_by(id: id)
      end
    end

    # A reminder aimed at someone else says so on the row. Without it the two
    # are indistinguishable in the list, and "did that go to Chelsea or to me?"
    # has no answer short of opening it.
    def when_text(reminder, user)
      base = reminder.recurring? ? recurrence_text(reminder) : reminder.fire_at.in_time_zone(user.timezone).strftime("%a %-I:%M %p")
      base = "#{base}, #{stops_at(reminder)}" if stops_at(reminder)
      return base if reminder.notify_user_id.blank?

      "to #{reminder.notify_user&.first_name || "someone else"} · #{base}"
    end

    # The rule that ENDS it, which lives on a separate watch and so was
    # invisible here — the list showed a repeat with no ending next to a
    # companion that had just promised one, which reads as the promise being
    # false. It's the same row as far as anyone using this is concerned.
    def stops_at(reminder)
      watch = BuddyWatch.where(user_id: reminder.user_id, kind: :cancel, cancelled_at: nil, fired_at: nil)
        .find { |w| w.cancels_reminder_id == reminder.id }
      return nil if watch.nil?

      Buddy::WatchCondition.until_phrase(watch.metadata.to_h["human_when"].presence || watch.body)
    end

    def recurrence_text(reminder)
      rec  = reminder.normalized_recurrence
      hhmm = (Time.zone.parse(rec["at"].to_s) rescue nil)
      tstr = hhmm ? hhmm.strftime("%-I:%M %p") : rec["at"].to_s
      ends = rec["until_on"].present? ? " until #{rec["until_on"]}" : ""
      # A window covering the whole day is not a window, and naming its edges
      # is how "until 11:59pm" turned up on a rule that ends when a print does.
      return "#{repeat_phrase(rec)}#{ends}" if all_day?(rec)

      "#{repeat_phrase(rec)} at #{tstr}#{ends}"
    end

    # Round the clock: `every_minutes` stepping from midnight to the last
    # minute of the day.
    def all_day?(rec)
      rec["every_minutes"].to_i.positive? && rec["at"].to_s == "00:00" && rec["until_at"].to_s >= "23:59"
    end

    DAY_NAMES = {
      "sun" => "Sunday",
      "mon" => "Monday",
      "tue" => "Tuesday",
      "wed" => "Wednesday",
      "thu" => "Thursday",
      "fri" => "Friday",
      "sat" => "Saturday",
    }.freeze
    ORDINAL_NAMES = { 1 => "first", 2 => "second", 3 => "third", 4 => "fourth", -1 => "last" }.freeze

    # The rule in words, shared by the panel's sublabel and schedule_reminder's
    # receipt so the two can never describe the same rule differently.
    def repeat_phrase(rec)
      rec = rec.with_indifferent_access
      # An intraday window is a rule about MINUTES that happens to recur across
      # days, so the day pattern is the small half of it and reading only that
      # half describes a different reminder. Asked to check a printer every 30
      # minutes, the chip came back "Byte will remind you every day at 5:19pm"
      # over a row that was going to nudge fourteen times before midnight
      # (dev 4091). The row was right; the read-back was a different reminder.
      return intraday_phrase(rec) if rec[:every_minutes].to_i.positive?

      case rec[:freq].to_s
      when "daily"    then "every day"
      when "weekdays" then "every weekday"
      when "weekly"   then "every #{named_days(rec[:by_day])}"
      when "yearly"   then "once a year"
      when "monthly"  then monthly_phrase(rec)
      when "custom"   then custom_phrase(rec)
      else                 "on a schedule"
      end
    end

    # "every 30 min", and the day pattern only when it's something other than
    # the plain every-day it nearly always is.
    def intraday_phrase(rec)
      step  = Buddy::Timers.humanize_seconds(rec[:every_minutes].to_i * 60)
      shape = rec[:freq].to_s
      band  = (" on #{repeat_phrase(rec.except(:every_minutes))}" unless shape == "daily")

      "every #{step}#{band}"
    end

    def monthly_phrase(rec)
      return "day #{Array(rec[:by_month_day]).join(", ")} monthly" if rec[:by_set_pos].blank?

      "the #{ORDINAL_NAMES[rec[:by_set_pos].to_i] || rec[:by_set_pos]} #{named_days(rec[:by_day])} monthly"
    end

    def custom_phrase(rec)
      count = rec[:interval].to_i
      unit  = rec[:unit].to_s.presence || "day"
      count > 1 ? "every #{count} #{unit}s" : "every #{unit}"
    end

    def named_days(keys)
      names = Array(keys).filter_map { |k| DAY_NAMES[k.to_s] }
      names.presence&.to_sentence || "week"
    end

    def watch_glyph(scope)
      case scope.to_s
      when "travel"           then "📍"
      when "chore_completion" then "✅"
      when "event"            then "📝"
      when "agenda_item"      then "📅"
      when "deploy"           then "🚀"
      when "item", "list", "section" then "🧾"
      # A custom listener can name any scope, so this is a real fallback now
      # rather than a defensive one.
      else "🔔"
      end
    end

    # Plain description on top; for a hand-written watch, its listener goes
    # underneath as the detail line. The description says what they asked for,
    # the listener says what's actually being matched - and when a custom watch
    # fires on something surprising, that second line is the only thing that
    # explains it.
    def watch_when(watch)
      phrase = (watch.metadata.is_a?(Hash) ? watch.metadata["human_when"].to_s.presence : nil)
      phrase ||= watch.trigger_scope.to_s
      # A watch that stops on its own should say so on the row. Otherwise the
      # only way to tell a standing watch from a today-only one is to open it.
      phrase = "#{phrase} · until #{expiry_phrase(watch)}" if watch.expires_at.present?
      return phrase if watch.listener.blank?

      "#{phrase}\n#{watch.listener}"
    end

    def expiry_date(watch, user)
      return nil if watch.expires_at.blank?

      watch.expires_at.in_time_zone(user.timezone).to_date
    end

    def expiry_phrase(watch)
      ends  = expiry_date(watch, watch.user)
      today = Time.current.in_time_zone(watch.user.timezone).to_date
      return "tonight" if ends <= today
      return "tomorrow" if ends == today + 1

      ends.strftime("%b %-e")
    end
  end
end
