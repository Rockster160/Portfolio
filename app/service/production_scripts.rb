require "open3"

# Approving and running ProductionScripts.
#
# A script runs the way `prodExec` runs a file - `rails runner` on it, in its
# own process - so it gets a fresh app, can't take a Sidekiq thread's state
# with it, and what it prints is its own. It runs when it is approved and its
# commit is already deployed, or else on the boot after the deploy that brings
# that commit in (Sidekiq's startup hook, ProductionScriptsDeployedWorker).
module ProductionScripts
  module_function

  def create!(user:, title:, code:, commit_sha:, edited_by:, feature_build: nil)
    user.production_scripts.create!(
      title:         title,
      code:          code,
      commit_sha:    commit_sha,
      edited_by:     edited_by,
      feature_build: feature_build,
    )
  end

  def edit!(script, code:, edited_by:, title: nil, commit_sha: nil)
    script.update!({ code: code, edited_by: edited_by, title: title, commit_sha: commit_sha }.compact)
    script
  end

  def approve!(script, by:)
    raise ArgumentError, "only the owner approves a production script" unless by&.me?
    raise ArgumentError, "#{script.status} scripts can't be approved" unless script.approvable?

    script.update!(status: :approved, approved_at: Time.current)
    ProductionScriptRunWorker.perform_async(script.id) if deployed?(script.commit_sha)
    script
  end

  def skip!(script)
    raise ArgumentError, "it's running" if script.status_running?

    script.update!(status: :skipped, approved_at: nil)
  end

  def restore!(script)
    script.update!(status: :pending) if script.status_skipped?
  end

  # Everything approved whose commit is now live.
  def run_deployed!
    ProductionScript.status_approved.find_each { |script|
      ProductionScriptRunWorker.perform_async(script.id) if deployed?(script.commit_sha)
    }
  end

  def run!(script)
    claimed = script.with_lock {
      next false unless script.status_approved?

      script.update!(status: :running, started_at: Time.current)
    }
    return script unless claimed

    output, status = execute(script)
    script.update!(
      status:      status&.success? ? :succeeded : :failed,
      exit_status: status&.exitstatus,
      output:      output.last(ProductionScript::OUTPUT_LIMIT),
      ran_at:      Time.current,
    )
    script
  end

  def execute(script)
    path = Rails.root.join("tmp", "production_scripts", "#{script.id}-#{Time.current.to_i}.rb")
    FileUtils.mkdir_p(path.dirname)
    File.write(path, script.code)
    Open3.capture2e(
      { "RAILS_ENV" => Rails.env },
      RbConfig.ruby, Rails.root.join("bin/rails").to_s, "runner", path.to_s,
      chdir: Rails.root.to_s
    )
  rescue StandardError => e
    ["#{e.class}: #{e.message}", nil]
  ensure
    FileUtils.rm_f(path) if path
  end

  # Whether the commit is in what is running now: an ancestor of the deployed
  # revision, asked of the repository Capistrano keeps beside the releases. A
  # commit that has never been pushed there, or a malformed one, isn't.
  def deployed?(sha)
    return false unless sha.to_s.match?(/\A\h{7,40}\z/)
    return true if deployed_revision.start_with?(sha)

    system(
      "git", "-C", repository.to_s, "merge-base", "--is-ancestor", sha, deployed_revision,
      out: File::NULL, err: File::NULL
    )
  end

  # Capistrano's mirror on the server; the checkout itself anywhere else.
  def repository
    mirror = Rails.root.join("../../repo")
    File.directory?(mirror) ? mirror : Rails.root
  end

  def deployed_revision
    return COMMIT_SHA if COMMIT_SHA.match?(/\A\h{7,40}\z/)

    Open3.capture2("git", "-C", Rails.root.to_s, "rev-parse", "HEAD").first.strip
  end
end
