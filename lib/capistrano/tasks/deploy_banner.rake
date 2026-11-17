require "active_support/time"
require "shellwords"
require_relative "../../deploy_banner"

namespace :deploy do
  # Marks the release in custom.log. A failure here is only a missing divider,
  # so it warns and never fails the deploy.
  task :log_banner do
    on(roles(:app)) {
      revision = fetch(:current_revision)
      message, last_change = within(repo_path) {
        [
          capture(:git, "log -1 --format=%B #{revision}"),
          capture(:git, "log -1 --no-merges --format=%s #{revision}"),
        ]
      }
      line = DeployBanner.line(
        time:    Time.now.in_time_zone("America/Denver"),
        subject: DeployBanner.subject(message, last_change: last_change),
      )
      execute "printf '%s\\n' #{Shellwords.escape(line)} >> #{shared_path}/log/custom.log"
    }
  rescue StandardError => e
    warn "Deploy banner not written: #{e.class}: #{e.message}"
  end
end

after "deploy:published", "deploy:log_banner"
