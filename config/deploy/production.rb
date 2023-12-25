# New person: Add their `id_rsa.pub` (or other desired key) to
# `Portfolio:/home/deploy/.ssh/authorized_keys`
server "138.68.3.152", user: :deploy, roles: [:app, :web, :db]

set :stage,           :production
set :rails_env,       :production
set :ssh_options, {
 keys: File.join(ENV["HOME"], ".ssh/id_rsa"),
 forward_agent: false,
 auth_methods: %w(publickey)
}
