class FireDueAgendaTriggersWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  # How far back we'll fire a past-due trigger and materialize missing
  # occurrences. Anything older is left ALONE — not fired, and never
  # auto-completed (we don't want to invent false history for a side-
  # effectful trigger that never actually ran).
  CATCHUP_WINDOW = 60.minutes

  def perform
    now = Time.current
    cutoff = now - CATCHUP_WINDOW
    materialize_due_trigger_phantoms!(now: now, cutoff: cutoff)

    # Dedup on `fired_at`, NOT on `completed_at` — completion is a manual
    # user action and must never be set automatically. A user who marks a
    # trigger complete before its start_at still skips firing because we
    # also exclude `incomplete=false` items below.
    AgendaItem.trigger
      .incomplete
      .where(fired_at: nil)
      .where(start_at: cutoff..now)
      .find_each do |item|
        fire(item)
      end
  end

  # Recurring trigger schedules only materialize a 7-day-ahead rolling
  # window on save (see AgendaSchedule#materialize_upcoming_triggers!). If
  # a schedule hasn't been saved within that window, today's occurrence
  # never gets a real AgendaItem row → the perform query above never sees
  # it → the trigger silently never fires. Bridge that gap here.
  def materialize_due_trigger_phantoms!(now:, cutoff:)
    AgendaSchedule.trigger.find_each do |schedule|
      agenda = schedule.agenda
      user = agenda.user
      tz_today = user.perceived_today
      # Two-date window covers a late-night trigger whose UTC date is yesterday
      # in the user's zone.
      [tz_today, tz_today - 1].each do |date|
        next unless schedule.matches?(date)

        occ_start = schedule.occurrence_start_at(date)
        next if occ_start > now || occ_start < cutoff
        next if schedule.agenda_items.exists?(start_at: agenda.send(:day_range, date))

        schedule.agenda_items.create!(
          agenda:             agenda,
          kind:               :trigger,
          name:               schedule.name,
          start_at:           occ_start,
          color:              schedule.color,
          notes:              schedule.notes,
          location:           schedule.location,
          trigger_expression: schedule.trigger_expression,
        )
      end
    end
  end

  def fire(item)
    scope, data = item.parsed_trigger
    if scope.blank?
      # No-op trigger expression — mark fired so we don't keep retrying,
      # but never touch completed_at (that's the user's column).
      item.update(fired_at: Time.current)
      return
    end

    if scope.to_s == "command"
      # `command:<text>` triggers run the text through Jarvis as if the user
      # had typed/said it — the same code path used for Alexa, SMS, terminal,
      # etc. Lets users schedule things like:
      #   command:"Remind me to wash dishes"
      words = extract_command_words(data)
      ::Jarvis.command(item.user, words) if words.present?
    else
      ::Jil.trigger(item.user, scope, data, auth: :agenda, auth_id: item.id)
    end

    item.update(fired_at: Time.current)
  rescue StandardError => e
    Rails.logger.error("[FireDueAgendaTriggersWorker] item=#{item.id} #{e.class}: #{e.message}")
    raise unless Rails.env.production?
  end

  # Pulls the words out of the parsed trigger data. The parser stores the
  # remainder of `command:"some text"` under the `:data` key (when there's a
  # single trailing segment); it also accepts nested forms by joining other
  # scalar values.
  def extract_command_words(data)
    return nil if data.blank?
    return data.to_s unless data.is_a?(::Hash)

    rest = data.except(:agenda_item)
    return rest[:data].to_s if rest[:data].is_a?(::String)

    rest.values.find { |v| v.is_a?(::String) }
  end
end
