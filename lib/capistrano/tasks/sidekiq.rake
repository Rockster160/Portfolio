namespace :sidekiq do
  desc "Start Sidekiq"
  task :start do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:stage) do
          execute "sudo /bin/systemctl start sidekiq"
        end
      end
    end
  end

  desc "Stop Sidekiq"
  task :stop do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:stage) do
          execute "sudo /bin/systemctl stop sidekiq"
        end
      end
    end
  end

  desc "Restart Sidekiq"
  task :restart do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:stage) do
          execute "sudo /bin/systemctl restart sidekiq"
        end
      end
    end
  end
end

after "deploy:published", "sidekiq:restart"
