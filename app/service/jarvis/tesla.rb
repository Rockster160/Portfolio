class Jarvis::Tesla < Jarvis::Action
  def self.reserved_words
    [:car, :tesla]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    cmd, params = parse_cmd_and_params
    response = TeslaCommand.command(cmd, params)
    if Rails.env.production?
      TeslaCommandWorker.perform_in(3.seconds, :update.to_s, nil, false) # to_s because Sidekiq complains
    end

    return response.presence || "Sent to Tesla"
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, Jarvis.reserved_words - self.class.reserved_words)

    @rx.match_any_words?(@msg, *car_commands)
  end

  def car_commands
    [
      :doors,
      :door,
      :windows,
      :window,
      :car,
      :tesla,
      :passenger,
      :seat,
      :update,
      :reload,
      :off,
      :stop,
      :on,
      :start,
      :close,
      :shut,
      :boot,
      :trunk,
      :lock,
      :unlock,
      :frunk,
      :temp,
      :cool,
      :heat,
      :warm,
      :find,
      :where,
      :honk,
      :horn,
      :vent,
      :defrost,
      :climate,
    ]
  end

  def parse_cmd_and_params
    words = @msg.downcase
    cmd = nil
    if words.match?(/#{@rx.words(:the, :my)} (\w+)$/)
      end_word = words[/\w+$/]
      words[/#{@rx.words(:the, :my)} (\w+)$/] = ""
      words = "#{end_word} #{words}"
    end

    words = words.gsub(@rx.words(:car, :tesla), "")
    words = words.gsub(/where\'?s?( is)?/, "find")
    words = words.gsub(/[^a-z0-9 ]/i, "")

    if @rx.match_any_words?(words, :open, :vent)
      words = words.gsub(@rx.words(:open), "") # Leave the vent word, if it's there
      words = "#{words} open"
    end

    words = words.gsub(/(.+)(#{@rx.words(car_commands)})/) do |found|
      cmd = Regexp.last_match(2)
      "#{Regexp.last_match(1)}"
    end

    words = words.gsub(@rx.words(:the, :set, :to, :is, :my, :me), "").squish

    [cmd, words].map(&:presence).compact # If no cmd, use the words
  end
end
