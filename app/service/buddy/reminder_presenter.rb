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
      reminder_rows(user, include_off) + watch_rows(user, include_off)
    end

    def reminder_rows(user, include_off)
      scope = BuddyReminder.where(user_id: user.id, fired_at: nil)
      scope = scope.where(cancelled_at: nil) unless include_off
      scope.order(:fire_at).limit(LIMIT).map { |r|
        {
          type:      :reminder,
          record_id: r.id,
          glyph:     r.recurring? ? "🔁" : "⏰",
          label:     r.body.to_s.truncate(80),
          sublabel:  when_text(r, user),
          enabled:   r.cancelled_at.nil?,
        }
      }
    end

    def watch_rows(user, include_off)
      scope = BuddyWatch.where(user_id: user.id, fired_at: nil)
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
      scope = scope.where(cancelled_at: nil) unless include_off
      scope.order(:created_at).limit(LIMIT).map { |w|
        {
          type:      :watch,
          record_id: w.id,
          glyph:     watch_glyph(w.trigger_scope),
          label:     w.body.to_s.truncate(80),
          sublabel:  watch_when(w),
          enabled:   w.cancelled_at.nil?,
        }
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

    def when_text(reminder, user)
      return recurrence_text(reminder) if reminder.recurring?

      reminder.fire_at.in_time_zone(user.timezone).strftime("%a %-I:%M %p")
    end

    # Mirrors schedule_reminder's receipt phrasing for a recurrence hash.
    def recurrence_text(reminder)
      rec  = reminder.recurrence || {}
      hhmm = (Time.zone.parse(rec["at"].to_s) rescue nil)
      tstr = hhmm ? hhmm.strftime("%-I:%M %p") : rec["at"].to_s
      base = case rec["kind"]
      when "daily"    then "every day"
      when "weekdays" then "every weekday"
      when "weekly"   then "every #{rec["weekday"].to_s.capitalize}"
      when "monthly"  then "day #{rec["day"]} monthly"
      else                 "on a schedule"
      end
      "#{base} at #{tstr}"
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
      return phrase if watch.listener.blank?

      "#{phrase}\n#{watch.listener}"
    end
  end
end
