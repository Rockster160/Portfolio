class Jarvis::Navigate < Jarvis::Action
  def self.reserved_words
    [:navigate, :drive, "go to", "take me", "take us"]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    # If specify nearest, search based on location.
    # Otherwise use the one in contacts and fallback to nearest to house
    response = TeslaCommand.quick_command(:navigate, parse_params)

    return response.presence || "Sent to Tesla"
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

    words = words.gsub(/(.+)(#{@rx.words(drive_commands)})/) { |_found|
      Regexp.last_match(1).to_s
    }

    words = words.gsub(@rx.words(drive_commands), "")
    words = words.gsub(@rx.words(:the, :set, :to, :is, :my, :me, :us), "")

    words.squish
  end
end
