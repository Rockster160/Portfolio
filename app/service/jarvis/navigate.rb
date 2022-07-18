class Jarvis::Navigate < Jarvis::Action
  def self.reserved_words
    [:navigate, :take, :drive, "go to", "take me"]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    response = TeslaCommand.command(:navigate, parse_params)

    return response.presence || true # Even if no response is returned, still return true since it did stuff
  end

  def valid_words?
    @rx.match_any_words?(@msg, *drive_commands) || @msg.squish.match?(/^#{address_regex}$/)
  end

  def address_regex
    @address_regex ||= ::Jarvis::Regex.address
  end

  def drive_commands
    self.class.reserved_words
  end

  def parse_params
    address = @msg[address_regex]
    return address if address.present?

    words = @msg
    if words.match?(/#{@rx.words(:the, :my)} (\w+)$/)
      end_word = words[/\w+$/]
      words[/#{@rx.words(:the, :my)} (\w+)$/] = ""
      words = "#{end_word} #{words}"
    end

    words = words.gsub(/(.+)(#{@rx.words(drive_commands)})/) do |found|
      "#{Regexp.last_match(1)}"
    end

    words = words.gsub(@rx.words(drive_commands), "")
    words = words.gsub(@rx.words(:the, :set, :to, :is, :my, :me), "")

    words.squish
  end
end
