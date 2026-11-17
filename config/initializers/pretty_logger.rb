# Override default from PrettyLogger
::PrettyLogger::RequestLogger.class_eval do
  def instance
    if Rails.env.local?
      @instance ||= ::ActiveSupport::Logger.new("log/custom.log")
    else
      @instance ||= ::ActiveSupport::Logger.new("/home/deploy/apps/portfolio/shared/log/custom.log")
    end
  end

  def pretty_user
    return colorize(:grey, "[#{request.ip}]\n") if current_user.blank?
    return colorize(:grey, "Guest:#{current_user.id}\n") if current_user.guest?

    name = current_user.try(:username).presence
    name ||= "#{current_user.guest? ? :Guest : :User}:#{current_user.id}"

    formatted = (
      case current_user.id
      when 1 then colorize(:rocco, "[R]")
      when 4 then colorize(:purple, "[M]")
      when 58_128 then "\e[94m[Her \e[95m♥\e[94m]\e[0m"
      when 34_226 then colorize(:pink, "[S]") # Saya
      when 37_764 then colorize(:yellow, "[C]") # Carlos
      else colorize(:olive, "[#{name}]")
      end
    )
    "#{formatted}\n"
  end
end

# A long unbroken run of token characters - base64, a key, a signature - is
# noise in the log. It keeps its ends and its length, "c4Df..2400c..tEMn", so
# two can still be told apart. Prepended so it wraps the gem's `params`, which
# both the request line and the error line print from.
module PrettyLoggerShortTokens
  TOKEN = %r{[A-Za-z0-9+/=_-]{100,}}

  def params
    shorten_tokens(super)
  end

  def shorten_tokens(value)
    case value
    when Hash then value.transform_values { |item| shorten_tokens(item) }
    when Array then value.map { |item| shorten_tokens(item) }
    when String then value.gsub(TOKEN) { |token| "#{token.first(4)}..#{token.length}c..#{token.last(4)}" }
    else value
    end
  end
end

# Payloads that are mostly the same boilerplate every time log only the parts
# that say what happened. A slice is either `keep:` - the keys to show, where
# an array is a path into the payload and anything not there is left out -
# with request headers to add under names of their own, or a lambda for a
# payload whose useful part changes from one to the next.
#
# A request is sliced by its path, and a Jil trigger's log line by its scope,
# since the same payload often arrives as one and is passed on as the other.
module PrettyLoggerSlices
  # A telemetry record is one or two changed fields wrapped in the car's id,
  # its own clock and a routing envelope. Only the changed fields are news.
  TESLA_TELEMETRY = ->(payload) {
    changed = payload[:data].to_h.symbolize_keys.except(:CreatedAt, :Vin)
    changed.delete(:IsResend) unless changed[:IsResend]
    # An encoded polyline, unreadable and often thousands of characters.
    changed[:RouteLine] &&= "#{changed[:RouteLine].to_s.length}c polyline"
    changed[:msg] = payload[:msg] unless payload[:msg] == "record_payload"
    changed
  }

  SLICES = {
    github:          {
      headers: { event: "X-GitHub-Event" },
      keep:    [
        :action,
        :ref,
        :after,
        [:head_commit, :message],
        [:pull_request, :number],
        [:pull_request, :title],
        [:pull_request, :merged],
        [:review, :state],
        [:comment, :body],
        [:workflow_job, :name],
        [:workflow_job, :status],
        [:workflow_job, :conclusion],
        [:workflow_run, :name],
        [:workflow_run, :status],
        [:workflow_run, :conclusion],
        [:sender, :login],
      ],
    },
    # The slots are what was said; the device is which Echo heard it; reason
    # and error are how a session that went wrong says why.
    alexa:           {
      keep: [
        [:request, :type],
        [:request, :intent, :name],
        [:request, :intent, :slots, :control, :value],
        [:request, :intent, :slots, :device, :value],
        [:request, :reason],
        [:request, :error],
        [:context, :System, :device, :deviceId],
      ],
    },
    tesla_telemetry: TESLA_TELEMETRY,
  }.freeze

  PATHS = {
    "/webhooks/github"          => :github,
    "/api/v1/alexa"             => :alexa,
    "/webhooks/tesla_telemetry" => :tesla_telemetry,
  }.freeze

  TRIGGERS = {
    tesla: :tesla_telemetry,
  }.freeze

  # What the executor logs for a trigger: the slice for its scope, or the
  # payload as it came.
  def self.for_trigger(trigger, payload)
    slice = SLICES[TRIGGERS[trigger&.to_sym]]
    return payload if slice.nil? || !payload.respond_to?(:to_h)

    apply(slice, payload.to_h.as_json.with_indifferent_access)
  end

  def self.apply(slice, full, headers: nil)
    return slice.call(full) if slice.respond_to?(:call)

    named = slice.fetch(:headers, {}).transform_values { |header| headers&.[](header) }.compact
    slice[:keep].each_with_object(named) { |path, kept|
      keys = Array(path)
      value = full.dig(*keys)
      next if value.nil?

      *parents, last = keys
      parents.inject(kept) { |level, key| level[key] ||= {} }[last] = value
    }
  end

  # Read from the body rather than `params`: Rails puts the route's own
  # `action` over a payload's, and GitHub's `action` is the one worth seeing.
  def params
    slice = SLICES[PATHS[request&.path]]
    return super if slice.nil?

    full = request.request_parameters.with_indifferent_access
    return super if full.blank?

    PrettyLoggerSlices.apply(slice, full, headers: request.headers)
  end
end

# Slices first, so the token shortening wraps what they keep.
::PrettyLogger::RequestLogger.prepend(PrettyLoggerSlices)
::PrettyLogger::RequestLogger.prepend(PrettyLoggerShortTokens)
