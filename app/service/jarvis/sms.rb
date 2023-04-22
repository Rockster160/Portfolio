# Might be special/not an integration
class Jarvis::Sms < Jarvis::Action
  def self.reserved_words
    [:text, :remind, :message, :msg, :sms, :txt, :tell, :ping]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    parse_text_words

    if @rx.match_any_words?(@msg, :remind)
      @user.default_list.add_items(name: @args)
    end

    if @rx.match_any_words?(@msg, :remind, :ping, :tell)
      ::WebPushNotifications.send_to(@user, { title: @args })
      "Sending you a ping saying: #{@args}"
    else
      ::SmsWorker.perform_async(::Jarvis::MY_NUMBER, @args)
      "Sending you a text saying: #{@args}"
    end
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
      *self.class.reserved_words,
      suffix: "s\?",
    )
  end

  def pre_words
    @rx.words(
      :send,
      :shoot,
      :tell,
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
      :ping,
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
