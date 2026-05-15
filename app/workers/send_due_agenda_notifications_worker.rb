# Push-notifies every accessing user (owner + share recipients) about each
# task/event whose start_at has just passed. Runs every minute via
# Sidekiq-cron, alongside FireDueAgendaTriggersWorker which handles the
# kind=:trigger items separately.
#
# Dedup is per (item, user) — once we've pushed someone for an item, their
# user_id lands in `agenda_items.notified_user_ids` and we never retry. This
# means even a missed run (sidekiq paused, server reboot) catches up cleanly
# the next time through.
class SendDueAgendaNotificationsWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  # Cap how far back we'll notify. A user who comes online after being
  # offline for a day shouldn't get a wall of 50 buzzes for events long past.
  CATCHUP_WINDOW = 30.minutes

  def perform
    now = Time.current
    cutoff = now - CATCHUP_WINDOW

    # Tasks + events: incomplete-only — a task you've checked off doesn't
    # need a buzz. `notified_at IS NULL` is the broadcast-attempt guard:
    # once we've tried this item, we don't try again, even if a user later
    # toggles notifications on (no retroactive pings for past events).
    AgendaItem
      .where(kind: [:task, :event])
      .incomplete
      .where(notified_at: nil)
      .where(start_at: cutoff..now)
      .find_each { |item| notify_for(item) }

    # Triggers: NOT filtered by incomplete because FireDueAgendaTriggersWorker
    # auto-marks them completed after firing the Jil/Jarvis action. Same
    # notified_at guard applies.
    AgendaItem
      .trigger
      .where(notified_at: nil)
      .where(start_at: cutoff..now)
      .find_each { |item| notify_for(item) }

    materialize_due_phantoms!(now: now, cutoff: cutoff)
  end

  def notify_for(item)
    agenda = item.agenda
    recipients = agenda.access_users.to_a # owner + share users
    recipients.each do |user|
      setting = AgendaNotificationSetting.for(user, agenda)
      next unless setting.notify_for?(item)

      ::WebPushNotifications.send_to(user, build_payload(item, user), channel: :agenda)
    end
    # Mark notified UNCONDITIONALLY — even if no recipients were eligible.
    # The user explicitly wants "attempted once, never retried", to avoid
    # retroactive notifications when settings change later.
    item.mark_notified!
  rescue StandardError => e
    Rails.logger.error("[SendDueAgendaNotificationsWorker] item=#{item.id} #{e.class}: #{e.message}")
    raise unless Rails.env.production?
  end

  # Recurring tasks/events stay phantom until interacted with — there's no
  # row in agenda_items for an upcoming Tuesday occurrence of a daily task.
  # When that Tuesday occurrence's start_at just passed, materialize it so
  # we have a row to (a) attach notified_user_ids to and (b) interact with.
  # Triggers do NOT need this here — they're materialized 7 days ahead via
  # AgendaSchedule#materialize_upcoming_triggers!.
  def materialize_due_phantoms!(now:, cutoff:)
    AgendaSchedule.where(kind: [:task, :event]).find_each do |schedule|
      agenda = schedule.agenda
      tz_today = agenda.user.perceived_today
      [tz_today, tz_today - 1].each do |date|
        next unless schedule.matches?(date)

        occ_start = schedule.occurrence_start_at(date)
        next if occ_start > now || occ_start < cutoff

        # Existing row for this occurrence? Skip materialization but still
        # try to notify (the prior find_each loop will have hit it).
        next if schedule.agenda_items.exists?(start_at: agenda.send(:day_range, date))

        item = schedule.agenda_items.create!(
          agenda:    agenda,
          kind:      schedule.kind,
          name:      schedule.name,
          start_at:  occ_start,
          end_at:    schedule.occurrence_end_at(date),
          color:     schedule.color,
          notes:     schedule.notes,
          location:  schedule.location,
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
    body_parts << "(#{item.agenda.name})"
    {
      title: item.name.presence || item.kind.to_s.capitalize,
      body:  body_parts.join(" "),
      icon:  "/favicon/android-chrome-192x192.png",
      tag:   "agenda-item-#{item.id}",
      data:  { url: "/agenda" },
    }
  end
end
