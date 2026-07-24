# Explicitly require every tool declaration so their `Buddy::Tools.register`
# side effects fire at boot. Zeitwerk doesn't autoload these files because
# they don't define constants — they just mutate the registry.
Rails.application.config.after_initialize do
  Dir[Rails.root.join("app/service/buddy/tools/*.rb")].sort.each { |f| load f }
end
