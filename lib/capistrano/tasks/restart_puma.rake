namespace :deploy do
  desc "Restart Puma service"
  task :restart_puma do
    on roles(:app) do
      execute :sudo, "/bin/systemctl restart puma_portfolio_production"
    end
  end
end

after "deploy:published", "deploy:restart_puma"
