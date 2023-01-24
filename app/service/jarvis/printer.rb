class Jarvis::Printer < Jarvis::Action
  def self.reserved_words
    [:printer]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    response = PrinterCommand.command(@msg)

    return response.presence || "Sent to Printer"
  end

  def valid_words?
    @rx.match_any_words?(@msg, *printer_commands)
  end

  def printer_commands
    [
      :preheat,
      :printer,
    ]
  end
end
