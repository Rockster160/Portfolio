# Override default from PrettyLogger
::PrettyLogger::RequestLogger.class_eval do
  def pretty_user
    return colorize(:grey, "[?]") unless current_user.present?

    name = current_user.try(:username).presence
    name ||= "#{current_user.class.name}:#{current_user.id}"

    case current_user.id
    when 1 then colorize(:rocco, "[Me]")
    when 4 then colorize(:purple, "[Mom]")
    when 33529 then colorize(:magenta, "[Janaya]")
    else colorize(:olive, "#{name}")
    end
  end
end
