class GoogleCalendarSyncWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3

  # Pull all connected agendas whose last sync was > the stale threshold.
  # Threshold deliberately bigger than the cron interval so we don't
  # double-sync when push notifications are healthy.
  STALE_THRESHOLD = 15.minutes

  # `agenda_id, reason` form: sync just that calendar with a recorded
  # reason (webhook, poll, manual). No args: sync every stale calendar.
  # Catches exceptions so a single bad sync doesn't disappear into
  # Sidekiq's dead queue without an operator-visible signal — and so a
  # transient failure doesn't burn the 3-retry budget silently.
  def perform(agenda_id=nil, reason="manual")
    return unless ::Rails.env.production?
    return sync_all_stale if agenda_id.nil?

    agenda = ::Agenda.google.find_by(id: agenda_id)
    return unless agenda

    sync_one!(agenda, reason: reason.to_sym)
  end

  private

  def sync_one!(agenda, reason:)
    ::GoogleCalendar::Sync.new(agenda).run!(reason: reason)
    ensure_watch!(agenda.reload)
  rescue StandardError => e
    report_sync_failure!(agenda, e)
    raise # Let Sidekiq see it for the retry budget + dashboard visibility.
  end

  def sync_all_stale
    ::Agenda.google
      .where("synced_at IS NULL OR synced_at < ?", STALE_THRESHOLD.ago)
      .find_each do |agenda|
        ::GoogleCalendar::Sync.new(agenda).run!(reason: :poll)
        ensure_watch!(agenda.reload)
      rescue StandardError => e
        report_sync_failure!(agenda, e)
      end
  end

  # Single chokepoint for sync failures — guarantees they hit the logs
  # AND Slack, so "Never synced" forever in the UI doesn't go undiagnosed.
  # Includes a migration-shaped error hint so the most common cause is
  # immediately obvious to whoever's looking at the alert.
  def report_sync_failure!(agenda, error)
    hint = migration_hint(error)
    msg = "[GoogleCalendarSyncWorker] agenda=#{agenda.id} (#{agenda.name.inspect}) " \
          "FAILED #{error.class}: #{error.message}#{" — #{hint}" if hint}"
    ::Rails.logger.error(msg)
    ::Rails.logger.error(error.backtrace.first(10).join("\n")) if error.backtrace
    ::SlackNotifier.notify(msg) if ::Rails.env.production?
  rescue StandardError
    # Slack itself failing shouldn't shadow the original error.
  end

  def migration_hint(error)
    return nil unless error.is_a?(::NoMethodError) || error.is_a?(::ActiveModel::UnknownAttributeError) || error.message.match?(/unknown attribute|undefined method.*for #<Agenda/i)

    "looks like a missing migration — run `bundle exec rake db:migrate` in this environment."
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
