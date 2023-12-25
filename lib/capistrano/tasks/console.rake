# namespace :rails do
#   desc "Run the console on a remote server."
#   task :console do
#     on roles(:app) do |h|
#       execute_interactively "RAILS_ENV=#{fetch(:rails_env)} bundle exec rails console", h.user
#     end
#   end
#
#   def execute_interactively(command, user)
#     info "Connecting with #{user}@#{host}"
#     cmd = "ssh #{user}@#{host} -p 22 -t 'cd #{fetch(:deploy_to)}/current && #{command}'"
#     exec cmd
#   end
# end
