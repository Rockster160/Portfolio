# Tells the Mini a build's PR was merged or closed, so it closes the session
# and removes the worktree and the branch. Runs when GitHub's webhook arrives
# and the Mini didn't answer it: a merge while the Mini is asleep or restarting
# would otherwise leave its session open for good, since GitHub says it once.
class FeatureBuildFinishWorker
  include Sidekiq::Worker

  # Retried on a schedule of its own below, not Sidekiq's.
  sidekiq_options queue: :default, retry: false

  RETRY_IN = 15.minutes
  # A day of asking. Past that the Mini is down for longer than a restart, and
  # the build shows as still running on the Claude page.
  ATTEMPTS = 96

  def perform(build_id, merged, attempt=1)
    build = FeatureBuild.find_by(id: build_id)
    return if build.nil? || build.status_finished?

    unless ByteLocal.builder(:finish, build_id: build.id, merged: merged)
      self.class.perform_in(RETRY_IN, build.id, merged, attempt + 1) if attempt < ATTEMPTS
      return
    end

    FeatureBuilder.finished!(build, merged: merged)
  end
end
