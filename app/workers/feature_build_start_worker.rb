# Asks the Mini to start a `/feature` build. The Mini answers before the
# session is up, then reports its link and branch on its own
# (PATCH /webhooks/byte/builds/:id); this only has to get the request there.
class FeatureBuildStartWorker
  include Sidekiq::Worker

  # A second start would cut a second worktree for the same build.
  sidekiq_options queue: :default, retry: false

  # `title_from` is what a build with no chosen name is named for, before the
  # Mini is given the name for its session.
  def perform(build_id, title_from=nil)
    build = FeatureBuild.find_by(id: build_id)
    return unless build&.status_starting?

    name!(build, title_from) if title_from.present?
    pick_repo!(build)
    fields = {
      build_id:        build.id,
      title:           build.title,
      repo:            build.repo,
      branch_name:     FeatureBuilder::BranchName.for(build),
      request:         "#{build.request}\n\n#{FeatureBuilder::TEXTING}",
      kind:            build.kind,
      user_id:         build.user_id,
      conversation_id: build.byte_conversation_id,
    }
    # Signed here rather than when it was asked for, so the links are fresh
    # when the Mini fetches them.
    images = build.image_sources
    fields[:attachments] = images if images.any?
    started = ByteLocal.builder(:start, **fields)
    return if started

    build.update!(status: :failed, error: "the Mini didn't answer, so nothing was started.")
    FeatureBuilder.repaint!(build)
    FeatureBuilder.refresh_looks!(build.user)
  end

  # A name the model couldn't give leaves the build with its request's first
  # line.
  def name!(build, text)
    name = FeatureBuilder::Title.for(text, user: build.user)
    return if name.nil?

    name = "#{FeatureBuilder::Audit::PREFIX}#{name}" if build.kind_audit?
    build.update!(title: name)
    FeatureBuilder.repaint!(build)
  end

  # Only a feature build can be for another repo: an audit and a `/q` read
  # Portfolio. One carrying on from another build works where that one did.
  def pick_repo!(build)
    return unless build.kind_feature?

    parent = build.parent
    repo = (
      if parent && !parent.kind_quick?
        parent.repo
      else
        FeatureBuilder::Repos.for(build.request, user: build.user)
      end
    )
    build.update!(repo: repo) unless repo == build.repo
  end
end
