# config valid for current version and patch releases of Capistrano
lock "~> 3.19.2"

set :application, "portfolio"
set :repo_url, "https://github.com/Rockster160/portfolio.git"
set :user, :deploy
set :group, :deploy
set :runner, :deploy

set :db_user, "rails"

# set :bundle_binstubs_command, :binstubs

set :puma_threads,    [4, 16]
set :puma_workers,    0
set :pty,             true
set :use_sudo,        false
set :deploy_via,      :remote_cache
set :deploy_to,       "/home/#{fetch(:user)}/apps/#{fetch(:application)}"
set :puma_bind,       "unix://#{shared_path}/tmp/sockets/#{fetch(:application)}-puma.sock"
set :puma_state,      "#{shared_path}/tmp/pids/puma.state"
set :puma_pid,        "#{shared_path}/tmp/pids/puma.pid"
set :puma_access_log, "#{release_path}/log/puma.error.log"
set :puma_error_log,  "#{release_path}/log/puma.access.log"
set :puma_preload_app, true
set :puma_worker_timeout, nil
set :puma_init_active_record, true  # Change to false when not using ActiveRecord
set :bundle_flags, "--deployment --quiet"
set :bundle_env_variables, { "BUNDLE_FORCE_RUBY_PLATFORM" => "true" }

set :default_env, {
  path: "/home/deploy/.rbenv/plugins/ruby-build/bin:/home/deploy/.rbenv/shims:/home/deploy/.rbenv/bin:$PATH",
  rbenv_root: "/home/deploy/.rbenv"
}
set :rbenv_roles, :all
set :rbenv_ruby, "3.2.2"
set :rbenv_ruby_dir, "/home/deploy/.rbenv/versions/3.2.2"
set :rbenv_custom_path, "/home/deploy/.rbenv"

# Default branch is :master
# ask :branch, `git rev-parse --abbrev-ref HEAD`.chomp

# Default deploy_to directory is /var/www/my_app_name
# set :deploy_to, "/var/www/my_app_name"

# Default value for :format is :airbrussh.
# set :format, :airbrussh

# You can configure the Airbrussh format using :format_options.
# These are the defaults.
# set :format_options, command_output: true, log_file: "log/capistrano.log", color: :auto, truncate: :auto

# Default value for :pty is false
# set :pty, true

# Default value for :linked_files is []
# NOTE: When adding any files here,make sure to update `lib/capistrano/tasks/sync_linked.rake`
append :linked_files, "config/database.yml", ".env", ".env.production"

# Default value for linked_dirs is []
append :linked_dirs, "log", "tmp/pids", "tmp/cache", "tmp/sockets", "public/system", "vendor", "storage"

# Default value for default_env is {}
# set :default_env, { path: "/opt/ruby/bin:$PATH" }

# Default value for local_user is ENV['USER']
# set :local_user, -> { `git config user.name`.chomp }

# Default value for keep_releases is 5
# set :keep_releases, 5

# Uncomment the following to require manually verifying the host key before first deploy.
# set :ssh_options, verify_host_key: :secure

set :puma_port, 3141
