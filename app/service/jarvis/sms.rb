class Jarvis::Sms < Jarvis::Action
  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    parse_text_words

    SmsWorker.perform_async(Jarvis::MY_NUMBER, @args)

    "Sending you a text saying: #{@args}"
  end

  def valid_words?
    @rx.match_any_words?(@msg, sms_words)
  end

  def parse_text_words
    @args = @msg.gsub(/#{pre_words}* ?#{sms_words} ?#{post_words}*/i, "")
    @args = @args.squish.tap { |words| words[0] = words[0]&.upcase }
  end

  def sms_words
    @rx.words(
      :text,
      :txt,
      :message,
      :msg,
      :sms,
      suffix: "s\?",
    )
  end

  def pre_words
    @rx.words(
      :send,
      :shoot,
      :me,
      :a,
      :text,
      :which,
      :that,
      :says,
      :saying,
      :txt,
      :sms,
      :to,
      :me,
      prefix: " ?",
      suffix: "?",
    )
  end

  def post_words
    @rx.words(
      :to,
      :that,
      :which,
      :me,
      :saying,
      :says,
      prefix: " ?",
      suffix: "?",
    )
  end
end
