# Might be special/not an integration
class Jarvis::Sms < Jarvis::Action
  def self.reserved_words
    [:text, :remind, :message, :msg, :sms, :txt]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    parse_text_words

    SmsWorker.perform_async(Jarvis::MY_NUMBER, @args)

    "Sending you a text saying: #{@args}"
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, Jarvis.reserved_words - self.class.reserved_words)

    @rx.match_any_words?(@msg, sms_words)
  end

  def parse_text_words
    @args = @msg.gsub(/#{pre_words}* ?#{sms_words} ?#{post_words}*/i, "")
    @args = @args.squish.presence&.tap { |words| words[0] = words[0]&.upcase }
    @args = @args || "You asked me to text you, sir."
  end

  def sms_words
    @rx.words(
      :text,
      :remind,
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
      :later,
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
