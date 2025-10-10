# New person: Add their `id_rsa.pub` (or other desired key) to
# `Portfolio:/home/deploy/.ssh/authorized_keys`
server "165.227.15.235", user: :deploy, roles: [:app, :web, :db]

set :stage,           :production
set :rails_env,       :production
set :ssh_options, {
  keys:          File.join(Dir.home, ".ssh/id_rsa"),
  forward_agent: true,
  auth_methods:  %w[publickey],
}
