module ActionCableTelemetry
  RECENT_IDS_LIMIT = 10
  SKIPPED_TYPES = %w[ping welcome confirm_subscription reject_subscription disconnect].to_set.freeze

  attr_reader :last_transmitted_at, :transmissions_count, :recent_ids,
    :pings_count, :last_message_summary

  def transmit(cable_message)
    type = cable_message.is_a?(Hash) ? (cable_message[:type] || cable_message["type"]).to_s : ""
    @pings_count = (@pings_count || 0) + 1 if type == "ping"

    record_application_message(cable_message) unless SKIPPED_TYPES.include?(type)

    super
  end

  private

  def record_application_message(cable_message)
    @transmissions_count = (@transmissions_count || 0) + 1
    @last_transmitted_at = Time.current

    msg = cable_message.is_a?(Hash) ? cable_message[:message] || cable_message["message"] : nil
    return unless msg.is_a?(Hash)

    @last_message_summary = msg.keys.first(10).map(&:to_s).join(", ")

    tag = (msg[:id] || msg["id"] || msg[:channel] || msg["channel"]).to_s
    return if tag.blank?

    channel_id = (cable_message[:identifier] || cable_message["identifier"]).to_s
    channel_name = parse_channel_name(channel_id)
    @recent_ids ||= []
    @recent_ids.unshift({ tag: tag, channel: channel_name, at: Time.current })
    @recent_ids = @recent_ids.first(RECENT_IDS_LIMIT)
  end

  def parse_channel_name(channel_id)
    return nil if channel_id.blank?

    JSON.parse(channel_id)["channel"]
  rescue JSON::ParserError
    nil
  end
end

ActiveSupport.on_load(:action_cable) do
  ActiveSupport.on_load(:action_cable_connection) do
    prepend ActionCableTelemetry
  end
end
