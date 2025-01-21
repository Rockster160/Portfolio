# Load DSL and set up stages
require "capistrano/setup"

# Include default deployment tasks
require "capistrano/deploy"

require "capistrano/rails"
require "capistrano/rbenv"
require "capistrano/bundler"
require "capistrano/puma"
install_plugin Capistrano::Puma
install_plugin Capistrano::Puma::Systemd
require "capistrano/rails/assets"
require "capistrano/rails/migrations"
require "capistrano/scm/git"
install_plugin Capistrano::SCM::Git

# Load custom tasks from `lib/capistrano/tasks` if you have any defined
Dir.glob("lib/capistrano/tasks/*.rake").each { |r| import r }

namespace :puma do
  desc "Restart Puma service"
  task :restart do
    on roles(:app) do
      execute :sudo, "/bin/systemctl restart #{fetch(:puma_service_unit_name)}"
    end
  end
end
