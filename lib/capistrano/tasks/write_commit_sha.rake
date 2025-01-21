namespace :deploy do
  task :write_commit_sha do
    commit_sha = `git rev-parse HEAD`.strip
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:stage) do
          execute :echo, "#{commit_sha} > #{release_path}/REVISION" if commit_sha.present?
        end
      end
    end
  end
end

after "deploy:published", "deploy:write_commit_sha"
