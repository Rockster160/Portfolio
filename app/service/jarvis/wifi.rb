class Jarvis::Wifi < Jarvis::Action
  def self.reserved_words
    [:wifi]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    qr = Qr.wifi("Nighthawk", DataStorage[:WIFIPASS_Nighthawk])
    ::SmsWorker.perform_async(Jarvis::MY_NUMBER, qr)

    return "Sent"
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, Jarvis.reserved_words - self.class.reserved_words)

    @rx.match_any_words?(@msg, *wifi_commands)
  end

  def wifi_commands
    [
      :send,
      :wifi,
      :nighthawk,
    ]
  end

  def parse_cmd
    words = @msg.downcase
    if words.match?(/#{@rx.words(:the, :my)} (\w+)$/)
      end_word = words[/\w+$/i]
      words[/#{@rx.words(:the, :my)} (\w+)$/] = ""
      words = "#{end_word} #{words}"
    end

    words = words.gsub(@rx.words(:send), "")
    words = words.gsub(@rx.words(:the, :set, :to, :is, :my), "")

    words.squish
  end
end
