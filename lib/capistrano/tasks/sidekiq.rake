namespace :sidekiq do
  desc "Start Sidekiq"
  task :start do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:stage) do
          # puts "\e[35m[LOGIT] | DOING start\e[0m"
          # execute "sudo /bin/systemctl start sidekiq.service"
        end
      end
    end
  end

  desc "Stop Sidekiq"
  task :stop do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:stage) do
          # puts "\e[35m[LOGIT] | DOING stop\e[0m"
          # execute "sudo /bin/systemctl stop sidekiq.service"
        end
      end
    end
  end

  desc "Restart Sidekiq"
  task :restart do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:stage) do
          # puts "\e[35m[LOGIT] | DOING restart\e[0m"
          # execute "sudo /bin/systemctl restart sidekiq.service"
        end
      end
    end
  end
end

after "deploy:published", "sidekiq:restart"
