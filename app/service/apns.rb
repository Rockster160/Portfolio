# Apple Push Notification service over HTTP/2, authenticated with a .p8 signing
# key (token-based auth), so there is no certificate to expire once a year.
#
# Apple issues a key per environment: PORTFOLIO_APNS_KEY / _KEY_ID sign pushes
# to TestFlight and App Store builds, PORTFOLIO_APNS_SANDBOX_KEY / _KEY_ID to
# builds run from Xcode. A sandbox left unset uses the production key, which is
# right for a key Apple issued for both.
#
#   Apns.deliver(token: hex, payload: { aps: { alert: "Hi" } }, environment: "production")
#
# Returns an Apns::Result. The caller decides what a dead token means for its
# own row; this class only reports what Apple said.
class Apns
  HOSTS = {
    production:  "https://api.push.apple.com",
    development: "https://api.sandbox.push.apple.com",
  }.freeze
  # Apple rejects a provider token older than an hour and throttles one renewed
  # more often than every 20 minutes, so it is reused for most of that hour.
  TOKEN_TTL = 50.minutes
  # How long Apple keeps trying a phone that is off or has no signal. An alert
  # waits a day. A Live Activity or widget update is stale within the hour.
  # A silent push is never stored: Apple holds only one undelivered push per
  # app, and a stored silent one would take the place of a waiting alert.
  KEEP_FOR = { alert: 1.day, liveactivity: 1.hour, widgets: 1.hour }.freeze
  TIMEOUT = 10
  # Statuses that mean the device token will never work again.
  DEAD_REASONS = [:BadDeviceToken, :Unregistered, :DeviceTokenNotForTopic, :ExpiredToken].freeze

  Result = Struct.new(:status, :reason, :apns_id, keyword_init: true) {
    def ok? = status.to_i == 200
    def dead_token? = status.to_i == 410 || DEAD_REASONS.include?(reason&.to_sym)
  }

  MUTEX = Mutex.new

  class << self
    def configured?(env=:production)
      key_pem(env).present? && key_id(env).present? && team_id.present?
    end

    def topic
      ENV.fetch("PORTFOLIO_APNS_TOPIC", "com.ardesian.buddy")
    end

    # push_type: :alert, :background, :liveactivity, :widgets
    def deliver(
      token:,
      payload:,
      environment: nil,
      push_type: :alert,
      priority: nil,
      collapse_id: nil,
      expiration: nil,
      topic_suffix: nil)
      return Result.new(status: 0, reason: :NoToken) if token.blank?

      env = environment.to_s == "development" ? :development : :production
      if Rails.env.local?
        log_only(token, push_type, payload)
        return Result.new(status: 200, reason: :Logged)
      end
      return Result.new(status: 0, reason: :NotConfigured) unless configured?(env)

      headers = {
        "authorization"   => "bearer #{provider_token(env)}",
        "apns-topic"      => [topic, topic_suffix].compact.join("."),
        "apns-push-type"  => push_type.to_s,
        "apns-priority"   => (priority || default_priority(push_type)).to_s,
        "apns-expiration" => (expiration || default_expiration(push_type)).to_i.to_s,
        "content-type"    => "application/json",
      }
      headers["apns-collapse-id"] = collapse_id.to_s.first(64) if collapse_id.present?
      call(env, "/3/device/#{token}", headers, payload.to_json)
    end

    private

    def default_expiration(push_type)
      keep = KEEP_FOR[push_type.to_sym]
      keep ? keep.from_now : 0
    end

    # Background pushes must be 5; Apple drops a 10 for content-available.
    def default_priority(push_type)
      push_type.to_sym == :background ? 5 : 10
    end

    def call(env, path, headers, body)
      response = MUTEX.synchronize {
        client(env).call(:post, path, body: body, headers: headers, timeout: TIMEOUT)
      }
      if response.nil?
        reset(env)
        return Result.new(status: 0, reason: :Timeout)
      end

      reason = (JSON.parse(response.body)["reason"] rescue nil) if response.body.present?
      Result.new(
        status:  response.status.to_i,
        reason:  reason&.to_sym,
        apns_id: response.headers["apns-id"],
      )
    rescue StandardError => e
      reset(env)
      Rails.logger.warn("[APNS] #{e.class}: #{e.message}")
      Result.new(status: 0, reason: e.class.name.to_sym)
    end

    # One HTTP/2 connection per environment, kept open: Apple asks providers
    # not to open a connection per push.
    def client(env)
      @clients ||= {}
      @clients[env] ||= NetHttp2::Client.new(HOSTS[env], connect_timeout: TIMEOUT).tap { |client|
        client.on(:error) { |error| Rails.logger.warn("[APNS] connection error: #{error.message}") }
      }
    end

    def reset(env)
      MUTEX.synchronize {
        @clients&.delete(env)&.close
      }
    rescue StandardError
      nil
    end

    # One per environment, each signed with that environment's key.
    def provider_token(env)
      MUTEX.synchronize {
        @provider_tokens ||= {}
        token, issued_at = @provider_tokens[env]
        if token.nil? || issued_at < TOKEN_TTL.ago
          key = OpenSSL::PKey::EC.new(key_pem(env))
          token = JWT.encode({ iss: team_id, iat: Time.current.to_i }, key, "ES256", { kid: key_id(env) })
          @provider_tokens[env] = [token, Time.current]
        end
        token
      }
    end

    # The key is stored as the .p8 file's text; an env var often carries its
    # newlines escaped.
    def key_pem(env)
      raw = env == :development ? ENV["PORTFOLIO_APNS_SANDBOX_KEY"].presence : nil
      (raw || ENV.fetch("PORTFOLIO_APNS_KEY", "")).gsub("\\n", "\n").presence
    end

    def key_id(env)
      sandbox = ENV["PORTFOLIO_APNS_SANDBOX_KEY_ID"].presence if env == :development
      sandbox || ENV.fetch("PORTFOLIO_APNS_KEY_ID", nil)
    end

    def team_id = ENV.fetch("PORTFOLIO_APNS_TEAM_ID", nil)

    def log_only(token, push_type, payload)
      return if Rails.env.test?

      Rails.logger.info("[APNS][#{push_type}] #{token.to_s.first(8)}… #{payload.to_json}")
    end
  end
end
