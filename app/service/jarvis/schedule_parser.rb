class Jarvis::ScheduleParser < Jarvis::Action
  def attempt
    return unless valid_words?

    ::Jarvis::Schedule.schedule(
      scheduled_time: @scheduled_time,
      user_id: @user.id,
      words: @remaining_words,
      type: :command,
    )
    @response = "I'll #{Jarvis::Text.rephrase(@remaining_words)} #{natural_time}"

    return @response.presence || "Sent to Schedule"
  end

  def natural_time
    relative_time.gsub(":00", "").gsub(/12 ?pm/i, "noon").gsub(/12 ?am/i, "midnight")
  end

  def relative_time
    if @scheduled_time.today?
      "today at #{@scheduled_time.strftime("%-l:%M%P")}"
    elsif @scheduled_time.tomorrow?
      "tomorrow at #{@scheduled_time.strftime("%-l:%M%P")}"
    else
      # Maybe even say things like "next Wednesday at ..."
      if Time.current.year == @scheduled_time.year
        "on #{@scheduled_time.strftime("%a, %b %-d at %-l:%M%P")}"
      else
        "on #{@scheduled_time.strftime("%a, %b %-d, %Y at %-l:%M%P")}"
      end
    end
  end

  def valid_words?
    time_str, @scheduled_time = Jarvis::Times.extract_time(@msg.downcase.squish, context: :future)
    return false unless @scheduled_time

    @remaining_words = @msg.sub(Regexp.new("(?:\b(?:at)\b )?#{time_str}", :i), "").squish

    @scheduled_time.present?
  end
end
