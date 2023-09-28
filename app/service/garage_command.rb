module GarageCommand
  module_function

  def set(state)
    state = state.to_sym
    return unless state.in?([:open, :closed, :between])

    User.me.jarvis_cache.set(:garage_state, state)
  end

  def command(dir_str)
    direction = :toggle if dir_str.match?(/(toggle|garage)/i)
    direction = :open if dir_str.match?(/(open)/i)
    direction = :close if dir_str.match?(/(clos)/i)
    direction ||= :toggle

    ActionCable.server.broadcast(:garage_channel, { msg: "#{direction}Garage" })

    case direction
    when :open then "Opening the garage"
    when :close then "Closing the garage"
    when :toggle then "Toggling the garage"
    end
  end
end
