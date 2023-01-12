class Jarvis::Bedtime < Jarvis::Action
  def self.reserved_words
    [:bed, :bedtime]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    before_bed = []
    if @user.default_list.list_items.any?
      before_bed << "Still todo:\n  #{@user.default_list.list_items.join("  \n")}"
    end
    # Check if garage is open
    # Check if Tesla is charging
    SmsWorker.perform_async(Jarvis::MY_NUMBER, before_bed.join("\n")) if before_bed.any?

    # No response- an sms is sent
    return true
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, Jarvis.reserved_words - self.class.reserved_words)

    @rx.match_any_words?(@msg, *bedtime_commands)
  end

  def bedtime_commands
    [
      *self.class.reserved_words,
    ]
  end
end
