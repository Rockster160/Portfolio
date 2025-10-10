class Jarvis::ScheduleParser < Jarvis::Action
  def attempt
    return unless valid_words?

    ::Jil::Schedule.add_schedule(@user.id, @scheduled_time, :command, { words: @remaining_words })
    @response = "I'll #{Jarvis::Text.rephrase(@remaining_words)} #{natural_time}"

    return @response.presence || "Sent to Schedule"
  end

  def natural_time
    relative_time.gsub(/12:00 ?pm/i, "noon").gsub(/12:00 ?am/i, "midnight").gsub(":00", "")
  end

  def relative_time
    if @scheduled_time.today?
      "today at #{@scheduled_time.strftime("%-l:%M%P")}"
    elsif @scheduled_time.tomorrow?
      "tomorrow at #{@scheduled_time.strftime("%-l:%M%P")}"
    elsif Time.current.year == @scheduled_time.year
      # Maybe even say things like "next Wednesday at ..."
      "on #{@scheduled_time.strftime("%a, %b %-d at %-l:%M%P")}"
    else
      "on #{@scheduled_time.strftime("%a, %b %-d, %Y at %-l:%M%P")}"
    end
  end

  def valid_words?
    # context can still be overridden with `x time ago`
    time_str, @scheduled_time = Jarvis::Times.extract_time(@msg.downcase.squish, context: :future)
    return false unless @scheduled_time

    @remaining_words = @msg.sub(Regexp.new("(?:\b(?:at)\b )?#{time_str}", :i), "").squish

    @scheduled_time.present?
  end
end
