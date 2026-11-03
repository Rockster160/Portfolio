# Error rows past ErrorReport::RETAIN_FOR. What has been decided about a failure
# (ErrorStatus) stays: an ignored failure that comes back after its rows have
# gone is still ignored.
class ErrorReportSweepWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  BATCH_SIZE = 5_000

  def perform
    ErrorReport.expired.in_batches(of: BATCH_SIZE).delete_all
  end
end
