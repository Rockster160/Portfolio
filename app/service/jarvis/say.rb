class Jarvis::Say < Jarvis::Action
  def self.reserved_words
    [:say]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    parse_text_words

    Jarvis.say(@args)
    @args
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, @current_reserved_words)

    @rx.match_any_words?(@msg, say_words)
  end

  def parse_text_words
    @args = @msg.gsub(/^#{say_words} /i, "")
    @args = @args.squish.presence || Jarvis::Text.im_here
  end

  def say_words
    @rx.words(*self.class.reserved_words)
  end
end
