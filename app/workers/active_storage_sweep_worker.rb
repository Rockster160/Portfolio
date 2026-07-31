# Purges ActiveStorage blobs no record ever claimed.
#
# Byte's image composer uploads to /byte/uploads BEFORE the message send, so a
# blob exists the moment an image is picked. Anything the send never claims —
# a chip removed from the tray, a composer abandoned, a send that failed
# permanently — is a file sitting in S3 forever. Rails has no built-in sweep for
# this; `ActiveStorage::Blob.unattached` is a scope you're expected to schedule
# yourself.
#
# GRACE exists because "unattached" is also true for the seconds between the
# upload and the send that claims it, and for an image sitting in the offline
# outbound queue waiting on a connection. A day is far past either.
class ActiveStorageSweepWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  GRACE = 1.day
  # Ceiling per run so a backlog drains over several nights instead of hammering
  # S3 in one pass.
  BATCH = 500

  def perform
    stale = ActiveStorage::Blob.unattached.where(created_at: ...GRACE.ago).limit(BATCH)
    swept = stale.count { |blob| purge(blob) }
    Rails.logger.info("[ActiveStorageSweep] purged #{swept} unattached blobs") if swept.positive?
  end

  private

  # One bad blob (already gone from the bucket, credentials rotated) shouldn't
  # abort the rest of the sweep.
  def purge(blob)
    blob.purge
    true
  rescue StandardError => e
    Rails.logger.warn("[ActiveStorageSweep] blob #{blob.id}: #{e.class}: #{e.message}")
    false
  end
end
