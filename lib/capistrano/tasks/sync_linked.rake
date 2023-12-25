namespace :deploy do
  namespace :check do
    before :linked_files, :set_database_yml do
      on roles(:app), in: :sequence, wait: 10 do
        upload! "config/database.yml", "#{shared_path}/config/database.yml"
        upload! ".env", "#{shared_path}/.env"
        upload! ".env.production", "#{shared_path}/.env.production"
      end
    end
  end
end
