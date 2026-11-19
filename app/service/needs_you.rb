# What the Feature Builder waits on the owner for, as the Mini's dashboard shows
# it (GET /webhooks/byte/needs_you): a PR waiting on their review, a build's
# session stopped on a question to them, a production script waiting on their
# approval. Longest waiting first within each; `kind` is :pull, :build or :script.
module NeedsYou
  module_function

  def call(user)
    pulls(user) + questions(user) + scripts(user)
  end

  # An open PR, in any repo, neither approved, held, landing nor asking
  # (MergeQueue.state).
  def pulls(user)
    open = FeatureBuild.where(user: user).unfinished.where.not(pr_url: nil)
    waiting = open.select { |build| MergeQueue.state(build) == :review }
    waiting.sort_by(&:updated_at).map { |build|
      item(
        kind:   :pull,
        title:  build.full_title,
        reason: "#{"#{build.repo_name} " unless build.portfolio?}Pull request ##{build.pr_number}",
        url:    build.pr_url,
        since:  build.updated_at,
      )
    }
  end

  def questions(user)
    FeatureBuilder.asking(user).map { |build|
      item(
        kind:   :build,
        title:  build.full_title,
        reason: "Question for you",
        url:    build.rc_url.presence || helpers.system_claude_url,
        since:  build.asked_at,
      )
    }
  end

  def scripts(user)
    ProductionScript.where(user: user).status_pending.order(:created_at).map { |script|
      item(
        kind:   :script,
        title:  script.title,
        reason: "Production script to approve",
        url:    helpers.system_production_scripts_url,
        since:  script.updated_at,
      )
    }
  end

  # Not waiting on the owner, but shown beside it: the approved PRs in the
  # order they'll merge, as the dashboard's Upcoming list draws them.
  def upcoming(user)
    MergeQueue.upcoming(user).map { |build|
      {
        kind:   "Merge",
        ticket: build.pr_number,
        title:  build.full_title,
        url:    build.pr_url,
        since:  build.approved_at&.iso8601,
      }
    }
  end

  def item(kind:, title:, reason:, url:, since:)
    { kind: kind, title: title, reason: reason, url: url, since: since&.iso8601 }
  end

  def helpers
    Rails.application.routes.url_helpers
  end
end
