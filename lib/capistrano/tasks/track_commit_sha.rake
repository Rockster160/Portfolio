namespace :deploy do
  task :write_commit_sha do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:stage) do
          commit_sha = capture("git rev-parse HEAD")
          execute :echo, "#{commit_sha} > #{release_path}/REVISION"
        end
      end
    end
  end
end

after "deploy:published", "deploy:write_commit_sha"
