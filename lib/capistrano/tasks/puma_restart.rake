namespace :puma do
  desc "Restart Puma service"
  task :restart do
    on roles(:app) do
      execute :sudo, "/bin/systemctl restart #{fetch(:puma_service_unit_name)}"
    end
  end
end
