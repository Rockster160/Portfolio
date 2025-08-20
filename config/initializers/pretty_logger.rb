# Override default from PrettyLogger
::PrettyLogger::RequestLogger.class_eval do
  def instance
    if Rails.env.development? || Rails.env.test?
      @instance ||= ::ActiveSupport::Logger.new("log/custom.log")
    else
      @instance ||= ::ActiveSupport::Logger.new("/home/deploy/apps/portfolio/shared/log/custom.log")
    end
  end

  def pretty_user
    return colorize(:grey, "[#{request.ip}]\n") unless current_user.present?
    return colorize(:grey, "Guest:#{current_user.id}\n") if current_user.guest?

    name = current_user.try(:username).presence
    name ||= "#{current_user.guest? ? :Guest : :User}:#{current_user.id}"

    formatted = (
      case current_user.id
      when 1 then colorize(:rocco, "[R]")
      when 4 then colorize(:purple, "[M]")
      when 58128 then colorize(:light_blue, "[AlchemiBluum 💕]")
      when 34226 then colorize(:pink, "[S]") # Saya
      when 37764 then colorize(:yellow, "[C]") # Carlos
      else colorize(:olive, "[#{name}]")
      end
    )
    "#{formatted}\n"
  end
end
