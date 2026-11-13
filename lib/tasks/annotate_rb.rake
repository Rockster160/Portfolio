# Dev only: production should never rewrite source files on db:migrate.
if Rails.env.development? && ENV["ANNOTATERB_SKIP_ON_DB_TASKS"].nil?
  require "annotate_rb"

  AnnotateRb::Core.load_rake_tasks
end
