# Pushes due tasks/events (and opted-in triggers) to every accessing user.
# Pairs with FireDueAgendaTriggersWorker which fires the trigger Jil/Jarvis
# actions; this also fires :agenda_event lifecycle triggers (action::started
# at start_at, action::ended at end_at) so Jil tasks can react to events
# crossing their start / end times — the Agenda-native replacement for the
# legacy `calendar:action:started` / `:ended` triggers that used to be
# emitted by Schedule records created from MacBook webhook ingest.
class SendDueAgendaNotificationsWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  # Cap on how far back we'll fire — prevents a long-offline user from
  # waking up to a wall of buzzes for events long past.
  CATCHUP_WINDOW = 30.minutes

  def perform
    now = Time.current
    cutoff = now - CATCHUP_WINDOW

    AgendaItem
      .where(kind: [:task, :event])
      .incomplete
      .where(notified_at: nil)
      .where(start_at: cutoff..now)
      .find_each { |item| notify_for(item) }

    # Triggers skip `incomplete` because FireDueAgendaTriggersWorker
    # auto-completes them after firing; `notified_at` is still the dedup.
    AgendaItem
      .trigger
      .where(notified_at: nil)
      .where(start_at: cutoff..now)
      .find_each { |item| notify_for(item) }

    # Event-end firing: only events have a meaningful end_at and the
    # `:agenda_event action::ended` semantics that downstream Jil tasks
    # care about. Dedup via the dedicated `ended_fired_at` column so this
    # doesn't fight with `notified_at` (which already represents start-time).
    AgendaItem
      .event
      .where(ended_fired_at: nil)
      .where(end_at: cutoff..now)
      .find_each { |item| fire_ended!(item) }

    materialize_due_phantoms!(now: now, cutoff: cutoff)
  end

  def notify_for(item)
    agenda = item.agenda
    agenda.access_users.find_each do |user|
      setting = AgendaNotificationSetting.for(user, agenda)
      next unless setting.notify_for?(item)

      ::WebPushNotifications.send_to(user, build_payload(item, user), channel: :agenda)
    end
    item.mark_notified!
    fire_started!(item) if item.event?
  rescue StandardError => e
    Rails.logger.error("[SendDueAgendaNotificationsWorker] item=#{item.id} #{e.class}: #{e.message}")
    raise unless Rails.env.production?
  end

  def fire_started!(item)
    ::Jil.trigger(
      item.user, :agenda_event,
      item.with_jil_attrs(action: :started, agenda_name: item.agenda.name)
    )
  end

  def fire_ended!(item)
    ::Jil.trigger(
      item.user, :agenda_event,
      item.with_jil_attrs(action: :ended, agenda_name: item.agenda.name)
    )
    item.update_columns(ended_fired_at: Time.current)
  rescue StandardError => e
    Rails.logger.error("[SendDueAgendaNotificationsWorker] item=#{item.id} fire_ended #{e.class}: #{e.message}")
    raise unless Rails.env.production?
  end

  # Recurring task/event occurrences stay phantom until interacted with,
  # so the find_each above wouldn't see them — materialize any phantom
  # whose start_at just landed in the catchup window, then notify.
  def materialize_due_phantoms!(now:, cutoff:)
    AgendaSchedule.where(kind: [:task, :event]).find_each do |schedule|
      agenda = schedule.agenda
      tz_today = agenda.user.perceived_today
      [tz_today, tz_today - 1].each do |date|
        next unless schedule.matches?(date)

        occ_start = schedule.occurrence_start_at(date)
        next if occ_start > now || occ_start < cutoff
        next if schedule.agenda_items.exists?(start_at: agenda.send(:day_range, date))

        item = schedule.agenda_items.create!(
          agenda:   agenda,
          kind:     schedule.kind,
          name:     schedule.name,
          start_at: occ_start,
          end_at:   schedule.occurrence_end_at(date),
          color:    schedule.color,
          notes:    schedule.notes,
          location: schedule.location,
        )
        notify_for(item)
      end
    end
  end

  def build_payload(item, _user)
    zone = item.user.timezone
    when_str = item.start_at.in_time_zone(zone).strftime("%-l:%M%P")
    body_parts = [when_str]
    body_parts << "@ #{item.location}" if item.location.present?
    {
      title: item.name.presence || item.kind.to_s.capitalize,
      body:  body_parts.join(" "),
      icon:  "/agenda_favicon/android-chrome-192x192.png",
      tag:   "agenda-item-#{item.id}",
      data:  { url: "/agenda" },
    }
  end
end
