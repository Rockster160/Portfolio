# Tells the Mini master has moved, so it checks every open build's PR against
# it and brings the ones that no longer merge back in line, one build at a time
# (Builder.sync! there). Queued by GitHub's push to master.
#
# A few quick tries cover a Mini mid-restart. Past that nothing is lost: the
# Mini checks again when it boots, when a build opens its PR, and on the next
# push to master.
class FeatureBuildSyncWorker
  include Sidekiq::Worker

  # Retried on a schedule of its own below, not Sidekiq's.
  sidekiq_options queue: :default, retry: false

  RETRY_IN = 30.seconds
  ATTEMPTS = 3

  def perform(attempt=1)
    return if ByteLocal.builder(:sync, build_id: 0)

    self.class.perform_in(RETRY_IN, attempt + 1) if attempt < ATTEMPTS
  end
end
