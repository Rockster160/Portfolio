# config valid for current version and patch releases of Capistrano
lock "~> 3.19.2"

set :application, "portfolio"
set :repo_url, "https://github.com/Rockster160/portfolio.git"
set :user, :deploy
set :group, :deploy
set :runner, :deploy

set :db_user, "rails"

# set :bundle_binstubs_command, :binstubs

# NOTE: these two are inert. capistrano3-puma renders them into
# shared/puma.rb, but the systemd unit runs
# `puma -C .../current/config/puma.rb` — the file in this repo — so
# shared/puma.rb is regenerated every deploy and never read. Thread and worker
# counts are set in config/puma.rb; change them there.
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
  path:       "/home/deploy/.rbenv/plugins/ruby-build/bin:/home/deploy/.rbenv/shims:/home/deploy/.rbenv/bin:$PATH",
  rbenv_root: "/home/deploy/.rbenv",
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
# Linked files are symlinked from shared/ and never travel with a deploy, so
# the copies in this repo are NOT what production reads. `cap production
# sync_linked:check` reports where the two have drifted; it reads this list, so
# there is nothing to keep in step when adding a file here.
#
# config/database.yml was in this list for years, and that is how production
# came to run on `pool: 5` while the copy in this repo claimed 22 with a
# comment explaining reasoning that had never applied — nothing in git, CI or
# code review could see the file actually being read. Both copies resolve the
# password through `<%= ENV['PORTFOLIO_DB_PASS'] %>`, so there was never
# anything server-specific in it to justify that cost. Removed 19 Aug 2026;
# shared/config/database.yml is left in place on the server, unused, as a
# rollback path.
append :linked_files, ".env", ".env.production"

# Default value for linked_dirs is []
append :linked_dirs, "log", "tmp/pids", "tmp/cache", "tmp/sockets", "public/system", "vendor",
  "storage"

# Default value for default_env is {}
# set :default_env, { path: "/opt/ruby/bin:$PATH" }

# Default value for local_user is ENV['USER']
# set :local_user, -> { `git config user.name`.chomp }

# Default value for keep_releases is 5
# set :keep_releases, 5

# Uncomment the following to require manually verifying the host key before first deploy.
# set :ssh_options, verify_host_key: :secure

set :puma_port, 3141
