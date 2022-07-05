class Jarvis::Schedule < Jarvis::Action
  def attempt
    return unless valid_words?

    JarvisWorker.perform_at(@scheduled_time, @user.id, @remaining_words)
    @response = "I'll #{Jarvis::Text.rephrase(@remaining_words)} later at #{@scheduled_time.to_formatted_s(:quick_week_time)}"

    return @response.presence || true # Even if no response is returned, still return true since it did stuff
  end

  def valid_words?
    time_str, @scheduled_time = Jarvis::Times.extract_time(@msg.downcase.squish)
    @remaining_words = @msg.sub(Regexp.new("(?:\b(?:at)\b )?#{time_str}", :i), "").squish if @scheduled_time

    @scheduled_time.present?
  end
end
