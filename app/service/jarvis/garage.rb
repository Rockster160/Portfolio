class Jarvis::Garage < Jarvis::Action
  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    response = GarageCommand.command(@msg)

    return response.presence || true # Even if no response is returned, still return true since it did stuff
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, :car, :tesla, :home, :house)

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
