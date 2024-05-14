# Override default from PrettyLogger
::PrettyLogger::RequestLogger.class_eval do
  def pretty_user
    return colorize(:grey, "[?]") unless current_user.present?
    return colorize(:grey, "Guest:#{current_user.id}") if current_user.guest?

    name = current_user.try(:username).presence
    name ||= "#{current_user.guest? ? :Guest : :User}:#{current_user.id}"

    case current_user.id
    when 1 then colorize(:rocco, "[Me]")
    when 4 then colorize(:purple, "[Mom]")
    when 33529 then colorize(:magenta, "[Janaya]")
    when 34226 then colorize(:pink, "[S]") # Saya
    when 37764 then colorize(:yellow, "[C]") # Carlos
    else colorize(:olive, "[#{name}]")
    end
  end
end
