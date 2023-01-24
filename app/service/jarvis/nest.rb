class Jarvis::Nest < Jarvis::Action
  def self.reserved_words
    [:house, :home]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    response = NestCommand.command(parse_cmd)
    if Rails.env.production?
      NestCommandWorker.perform_in(10.seconds, :update.to_s) # to_s because Sidekiq complains
    end

    return response.presence || "Sent to Nest"
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, Jarvis.reserved_words - self.class.reserved_words)

    @rx.match_any_words?(@msg, *home_commands)
  end

  def home_commands
    [
      :home,
      :house,
      :ac,
      :heat,
      :cool,
      :up,
      :rooms,
      :upstairs,
      :main,
      :entry,
      :entryway,
    ]
  end

  def parse_cmd
    words = @msg.downcase
    if words.match?(/#{@rx.words(:the, :my)} (\w+)$/)
      end_word = words[/\w+$/i]
      words[/#{@rx.words(:the, :my)} (\w+)$/] = ""
      words = "#{end_word} #{words}"
    end

    words = words.gsub(@rx.words(:home, :house), "")
    words = words.gsub(@rx.words(:ac), "cool")

    words = words.gsub(@rx.words(:the, :set, :to, :is, :my), "")

    words.squish
  end
end
