class Jarvis::Trigger < Jarvis::Action
  def self.reserved_words
    [:trigger]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    raw = @msg.sub(/^\s*trigger\s+/i, "").squish
    return "What should I trigger?" if raw.blank?

    # Split on first colon to separate scope from data
    # "whisper-quiet-mode" → scope="whisper-quiet-mode", data={}
    # "my-trigger:awesome sauce" → scope="my-trigger", data={data: "awesome sauce"}
    scope, raw_data = raw.split(":", 2)
    data = raw_data.present? ? TriggerData.parse(raw_data, as: @user) : {}

    ::Jil.trigger(@user, scope.strip, data)
    "Triggered #{scope.strip}"
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, @current_reserved_words)

    @msg.match?(/^\s*trigger\b/i)
  end
end
