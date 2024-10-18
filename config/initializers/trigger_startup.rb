Rails.application.config.after_initialize do
  $startup_complete ||= false
  if defined?(Puma) && !$startup_complete && !Rails.env.test? && !Rails.const_defined?("Console")
    $startup_complete = true
    file_path = Rails.root.join("config", "git_info.json")
    git_json = JSON.parse(File.read(file_path)) rescue {}
    ::Jil.trigger(User.me, :startup, git_json)
  end
end
