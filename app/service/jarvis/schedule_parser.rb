class Jarvis::ScheduleParser < Jarvis::Action
  def attempt
    return unless valid_words?

    ::Jarvis::Schedule.schedule(
      scheduled_time: @scheduled_time,
      user_id: @user.id,
      words: @remaining_words,
      type: :command,
    )
    @response = "I'll #{Jarvis::Text.rephrase(@remaining_words)} #{relative_time}"

    return @response.presence || true # Even if no response is returned, still return true since it did stuff
  end

  def relative_time
    if @scheduled_time.today?
      "today at #{@scheduled_time.strftime("%-l:%M %p")}"
    elsif @scheduled_time.tomorrow?
      "tomorrow at #{@scheduled_time.strftime("%-l:%M %p")}"
    else
      # Maybe even say things like "next Wednesday at ..."
      "on #{@scheduled_time.strftime("%a %b %-d at %-l:%M %p")}"
    end
  end

  def valid_words?
    time_str, @scheduled_time = Jarvis::Times.extract_time(@msg.downcase.squish, context: :future)
    return unless @scheduled_time

    @remaining_words = @msg.sub(Regexp.new("(?:\b(?:at)\b )?#{time_str}", :i), "").squish

    @scheduled_time.present?
  end
end
