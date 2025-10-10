class CaptureQueryStatsWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform
    PgHero.capture_query_stats
  end
end
