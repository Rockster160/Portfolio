class GoogleCalendarWatchRenewalWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  # Cron-driven (sidekiq-cron). Re-subscribes any channel within
  # Agenda::WATCH_RENEWAL_LEAD of expiry. Also re-subscribes channels that
  # have already expired (so a node-down period doesn't permanently drop us
  # to poll-only).
  def perform
    ::Agenda.due_for_watch_renewal.find_each do |agenda|
      ::GoogleCalendar::WatchManager.start!(agenda)
    rescue StandardError => e
      ::Rails.logger.warn("[GoogleCalendarWatchRenewalWorker] agenda=#{agenda.id} error=#{e.class}: #{e.message}")
    end
  end
end
