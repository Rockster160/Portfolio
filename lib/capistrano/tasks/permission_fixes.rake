namespace :deploy do
  desc "Clear bootsnap cache"
  task :clear_bootsnap_cache do
    on roles(:app) do
      # ensure deploy can remove everything under bootsnap
      execute :chmod, "-R u+rwx #{shared_path}/tmp/cache/bootsnap", raise_on_non_zero_exit: false

      # attempt to clear cache without aborting on failure
      begin
        execute :rm, "-rf #{shared_path}/tmp/cache/bootsnap"
      rescue SSHKit::Command::Failed
        info "Skipping bootsnap cache cleanup error"
      end
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
