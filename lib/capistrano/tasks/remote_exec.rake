namespace :remote do
  desc "Upload and execute a local Ruby file on production via rails runner"
  task :exec do
    file = ENV.fetch("FILE", nil)
    abort "Usage: cap production remote:exec FILE=path/to/script.rb" unless file
    abort "File not found: #{file}" unless File.exist?(file)

    remote_path = "/tmp/remote_exec_#{Time.now.to_i}.rb"

    on roles(:app) do |host|
      upload! file, remote_path

      deploy_to = fetch(:deploy_to)
      rails_env = fetch(:rails_env)
      rbenv_root = fetch(:rbenv_custom_path)
      ssh_key = fetch(:ssh_options)[:keys]

      cmd = [
        "ssh",
        "-tt",
        "-i",
        ssh_key,
        "-o",
        "StrictHostKeyChecking=no",
        "#{host.user}@#{host.hostname}",
        "export PATH=#{rbenv_root}/shims:#{rbenv_root}/bin:$PATH && " \
        "export RBENV_ROOT=#{rbenv_root} && " \
        "cd #{deploy_to}/current && " \
        "RAILS_ENV=#{rails_env} bundle exec rails runner #{remote_path} ; " \
        "rm -f #{remote_path}",
      ]

      system(*cmd)
    end
  end
end
