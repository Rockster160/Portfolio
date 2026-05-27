class GoogleCalendarSyncWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3

  # Pull all connected agendas whose last sync was > the stale threshold.
  # Threshold deliberately bigger than the cron interval so we don't
  # double-sync when push notifications are healthy.
  STALE_THRESHOLD = 15.minutes

  # `agenda_id, reason` form: sync just that calendar with a recorded
  # reason (webhook, poll, manual). No args: sync every stale calendar.
  def perform(agenda_id=nil, reason="manual")
    return sync_all_stale if agenda_id.nil?

    agenda = ::Agenda.google.find_by(id: agenda_id)
    return unless agenda

    ::GoogleCalendar::Sync.new(agenda).run!(reason: reason.to_sym)
    ensure_watch!(agenda.reload)
  end

  private

  def sync_all_stale
    ::Agenda.google
      .where("synced_at IS NULL OR synced_at < ?", STALE_THRESHOLD.ago)
      .find_each do |agenda|
        ::GoogleCalendar::Sync.new(agenda).run!(reason: :poll)
        ensure_watch!(agenda.reload)
      rescue StandardError => e
        ::Rails.logger.warn("[GoogleCalendarSyncWorker] agenda=#{agenda.id} error=#{e.class}: #{e.message}")
      end
  end

  # Lazily start a watch channel after the first successful sync. Renewal is
  # handled separately by GoogleCalendarWatchRenewalWorker. needs_watch?
  # short-circuits when a previous attempt was denied by Google (and the
  # cooldown hasn't expired).
  def ensure_watch!(agenda)
    return if agenda.synced_at.blank? # don't watch a calendar we haven't pulled yet
    return unless agenda.needs_watch?

    ::GoogleCalendar::WatchManager.start!(agenda)
  rescue StandardError => e
    ::Rails.logger.warn(
      "[GoogleCalendarSyncWorker] watch-start agenda=#{agenda.id} error=#{e.class}: #{e.message}",
    )
  end
end
