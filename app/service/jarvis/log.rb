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
    @evt[:data] = extract_data(new_words)
    new_words = new_words.gsub(/\s*\{.*\}\s*/, " ").squish if @evt[:data].present?
    @evt[:name], @evt[:notes] = new_words.gsub(/[.?!]$/i, "").squish.split(" ", 2)
    # Stupid Alexa tries to expand mg to milligrams
    @evt[:notes] = @evt[:notes]&.gsub(" milligrams", "mg")
  end

  def extract_data(str)
    match = str.match(/\{([^}]+)\}/)
    return unless match

    raw = match[1]
    pairs = raw.split(",").map { |pair|
      key, value = pair.split(":", 2).map(&:strip)
      next unless key.present? && value.present?

      parsed_value = case value
      when /\A-?\d+\z/ then value.to_i
      when /\A-?\d+\.\d+\z/ then value.to_f
      when /\A(true|false)\z/i then value.downcase == "true"
      else value
      end
      [key, parsed_value]
    }.compact
    pairs.any? ? pairs.to_h : nil
  end

  def create_event
    @evt_data = {
      name:      @evt[:name]&.tap { |n| n[0] = n[0].upcase if n.present? },
      notes:     @evt[:notes].presence,
      timestamp: @evt[:timestamp].presence,
      data:      @evt[:data].presence,
      user_id:   @user.id,
    }.compact

    @event = ActionEvent.create(@evt_data)
  end

  def broadcast_event
    ::Jil.trigger(@event.user, :event, @event.with_jil_attrs(action: :added))
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
          @evt_data[:timestamp].to_fs(:short)
        end
      )
      evt_words << "[#{day} #{@event.timestamp.to_fs(:short_time)}]"
    end

    evt_words.join(" ")
  end
end
