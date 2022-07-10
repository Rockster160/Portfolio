class Jarvis::Garage < Jarvis::Action
  def self.reserved_words
    [:garage]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    response = GarageCommand.command(@msg)

    return response.presence || true # Even if no response is returned, still return true since it did stuff
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, Jarvis.reserved_words - self.class.reserved_words)

    @rx.match_any_words?(@msg, *garage_commands)
  end

  def garage_commands
    [
      :open,
      :close,
      :overhead,
      :garage,
    ]
  end
end
