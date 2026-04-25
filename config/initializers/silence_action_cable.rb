# ActionCable broadcasts log the full payload at DEBUG. With Jil running, that
# floods the Rails log (5+ GB). Give AC its own logger filtered to WARN so real
# errors still surface but routine broadcast chatter is dropped.
Rails.application.config.after_initialize do
  silenced = ActiveSupport::Logger.new(Rails.root.join("log/#{Rails.env}.log"))
  silenced.level = ::Logger::WARN
  ::ActionCable.server.config.logger = ActiveSupport::TaggedLogging.new(silenced)
end
