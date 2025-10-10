# Override default from PrettyLogger
::PrettyLogger::RequestLogger.class_eval do
  def instance
    if Rails.env.local?
      @instance ||= ::ActiveSupport::Logger.new("log/custom.log")
    else
      @instance ||= ::ActiveSupport::Logger.new("/home/deploy/apps/portfolio/shared/log/custom.log")
    end
  end

  def pretty_user
    return colorize(:grey, "[#{request.ip}]\n") if current_user.blank?
    return colorize(:grey, "Guest:#{current_user.id}\n") if current_user.guest?

    name = current_user.try(:username).presence
    name ||= "#{current_user.guest? ? :Guest : :User}:#{current_user.id}"

    formatted = (
      case current_user.id
      when 1 then colorize(:rocco, "[R]")
      when 4 then colorize(:purple, "[M]")
      when 58_128 then "\e[94m[Her \e[95m♥\e[94m]\e[0m"
      when 34_226 then colorize(:pink, "[S]") # Saya
      when 37_764 then colorize(:yellow, "[C]") # Carlos
      else colorize(:olive, "[#{name}]")
      end
    )
    "#{formatted}\n"
  end
end
