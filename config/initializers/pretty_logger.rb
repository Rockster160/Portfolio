# Override default from PrettyLogger
::PrettyLogger::RequestLogger.class_eval do
  def instance
    if Rails.env.development?
      @instance ||= ::ActiveSupport::Logger.new("log/custom.log")
    else
      @instance ||= ::ActiveSupport::Logger.new("/home/deploy/apps/portfolio/shared/log/custom.log")
    end
  end

  def pretty_user
    return colorize(:grey, "[?]\n") unless current_user.present?
    return colorize(:grey, "Guest:#{current_user.id}\n") if current_user.guest?

    name = current_user.try(:username).presence
    name ||= "#{current_user.guest? ? :Guest : :User}:#{current_user.id}"

    "\b" + case current_user.id
    when 1 then colorize(:rocco, "[R]\n")
    when 4 then colorize(:purple, "[M]\n")
    when 33529 then colorize(:magenta, "[J]\n")
    when 34226 then colorize(:pink, "[S]\n") # Saya
    when 37764 then colorize(:yellow, "[C]\n") # Carlos
    else colorize(:olive, "[#{name}]\n")
    end
  end
end
