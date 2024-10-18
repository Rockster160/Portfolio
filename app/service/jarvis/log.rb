class Jarvis::Log < Jarvis::Action
  def attempt
    return unless valid_words?

    parse_log_data
    if create_event.persisted?
      broadcast_event
    else
      @event.errors.full_messages.join("\n").presence || "Failed to create log."
    end
  end

  def valid_words?
    @msg.match?(/^log\b/i)
  end

  def parse_log_data
    @evt = {}
    time_str, extracted_time = Jarvis::Times.extract_time(@msg.downcase.squish, context: :past)
    new_words = @msg.sub(Regexp.new("(?:\b(?:at)\b)? ?#{time_str}", :i), "") if extracted_time
    new_words = (new_words || @msg).gsub(/^log ?/i, "")
    @evt[:timestamp] = extracted_time
    @evt[:name], @evt[:notes] = new_words.gsub(/[.?!]$/i, "").squish.split(" ", 2)
    # Stupid Alexa tries to expand mg to milligrams
    @evt[:notes] = @evt[:notes]&.gsub(" milligrams", "mg")
  end

  def create_event
    @evt_data = {
      name: @evt[:name].tap { |n| n[0] = n[0].upcase },
      notes: @evt[:notes].presence,
      timestamp: @evt[:timestamp].presence,
      user_id: @user.id,
    }.compact

    @event = ActionEvent.create(@evt_data)
  end

  def broadcast_event
    ::Jil.trigger(@event.user_id, :event, @event.serialize.merge(action: :added))
    ActionEventBroadcastWorker.perform_async(@event.id)

    evt_words = ["Logged #{@event.name}"]
    evt_words << "(#{@event.notes})" if @evt_data[:notes].present?

    if @evt_data[:timestamp].present?
      day = (
        if @evt_data[:timestamp].today?
          "Today"
        elsif @evt_data[:timestamp].tomorrow?
          "Tomorrow"
        elsif @evt_data[:timestamp].yesterday?
          "Yesterday"
        else
          @evt_data[:timestamp].to_formatted_s(:short)
        end
      )
      evt_words << "[#{day} #{@event.timestamp.to_formatted_s(:short_time)}]"
    end

    evt_words.join(" ")
  end
end
