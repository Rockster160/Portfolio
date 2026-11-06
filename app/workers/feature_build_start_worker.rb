# Asks the Mini to start a `/feature` build. The Mini answers before the
# session is up, then reports its link and branch on its own
# (PATCH /webhooks/byte/builds/:id); this only has to get the request there.
class FeatureBuildStartWorker
  include Sidekiq::Worker

  # A second start would cut a second worktree for the same build.
  sidekiq_options queue: :default, retry: false

  def perform(build_id)
    build = FeatureBuild.find_by(id: build_id)
    return unless build&.status_starting?

    started = ByteLocal.builder(
      :start,
      build_id:        build.id,
      title:           build.title,
      request:         build.request,
      user_id:         build.user_id,
      conversation_id: build.byte_conversation_id,
    )
    return if started

    build.update!(status: :failed, error: "the Mini didn't answer, so nothing was started.")
    FeatureBuilder.repaint!(build)
  end
end
