set :application, "Portfolio"
set :repo_url, "https://github.com/Rockster160/Portfolio.git"
set :branch, "master"
set :deploy_to, "/var/www/portfolio"
set :linked_files, fetch(:linked_files, []).push("config/database.yml", ".env")
set :linked_dirs, fetch(:linked_dirs, []).push("log", "tmp/pids", "tmp/cache", "tmp/sockets", "public/system")

namespace :deploy do
  desc "Restart application"
  task :restart do
    on roles(:app), in: :sequence, wait: 5 do
      execute :touch, release_path.join('tmp/restart.txt')
    end
  end
  after :publishing, "deploy:restart"
  after :finishing, "deploy:cleanup"
end
