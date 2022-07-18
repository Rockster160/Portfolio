class Jarvis::Tesla < Jarvis::Action
  def self.reserved_words
    [:car, :tesla, :navigate, :take, :drive, "go to", "take me"]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    cmd, params = parse_cmd_and_params
    response = TeslaCommand.command(cmd, params)
    if Rails.env.production?
      TeslaCommandWorker.perform_in(3.seconds, :update.to_s, nil, false) # to_s because Sidekiq complains
    end

    return response.presence || true # Even if no response is returned, still return true since it did stuff
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, Jarvis.reserved_words - self.class.reserved_words)

    @rx.match_any_words?(@msg, *car_commands) || @msg.squish.match?(/^#{address_regex}$/)
  end

  def address_regex
    @address_regex ||= begin
      street_name_words = [
        :highway,
        :autoroute,
        :north,
        :south,
        :east,
        :west,
        :avenue,
        :lane,
        :road,
        :route,
        :drive,
        :boulevard,
        :circle,
        :street,
        :cir,
        :blvd,
        :hway,
        :st,
        :ave,
        :ln,
        :rd,
        :hw,
        :dr,
      ]
      /(suite|ste)? ?[0-9]+[ \w.,]*#{street_name_words}([ .,-]*[a-z0-9]*)*/i
    end
  end

  def car_commands
    [
      :doors,
      :door,
      :windows,
      :window,
      :car,
      :navigate,
      :drive,
      :take,
      :"go to",
      :tesla,
      :update,
      :reload,
      :off,
      :stop,
      :on,
      :start,
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
    address = @msg[address_regex]
    return [:navigate, address] if address.present?

    words = @msg.downcase
    cmd = nil
    if words.match?(/#{@rx.words(:the, :my)} (\w+)$/)
      end_word = words[/\w+$/]
      words[/#{@rx.words(:the, :my)} (\w+)$/] = ""
      words = "#{end_word} #{words}"
    end

    words = words.gsub(@rx.words(:car, :tesla), "")
    words = words.gsub(@rx.words(:take, :go, :drive), "navigate")
    words = words.gsub(/where\'?s?( is)?/, "find")

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
