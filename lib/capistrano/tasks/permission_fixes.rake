namespace :deploy do
  desc "Clear bootsnap cache"
  task :clear_bootsnap_cache do
    on roles(:app) do
      execute "rm -rf #{shared_path}/tmp/cache/bootsnap"
    end
  end
end
after "deploy:updated", "deploy:clear_bootsnap_cache"

namespace :deploy do
  desc "Verify all files are owned by deploy user"
  task :verify_permissions do
    on roles(:app) do
      execute "find #{fetch(:deploy_to)} ! -user deploy -exec ls -ld {} \\;"
    end
  end
end
after "deploy:finished", "deploy:verify_permissions"
