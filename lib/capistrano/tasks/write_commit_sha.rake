namespace :deploy do
  task :write_commit_sha do
    commit_sha = `git rev-parse HEAD`.strip
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:stage) do
          execute :echo, "#{commit_sha} > #{release_path}/REVISION" if commit_sha.length.positive?
        end
      end
      # The build's number - how many commits deep it is - so a screen can say
      # at a glance whether it's behind. Counted in the server's mirror, which
      # has the full history the CI checkout doesn't.
      within repo_path do
        execute :git, "rev-list --count #{fetch(:current_revision)} > #{release_path}/BUILD_NUMBER"
      end
    end
  end
end

after "deploy:published", "deploy:write_commit_sha"
