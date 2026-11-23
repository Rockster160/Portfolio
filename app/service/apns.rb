# Apple Push Notification service over HTTP/2, authenticated with a .p8 signing
# key (token-based auth), so there is no certificate to expire once a year.
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
  TIMEOUT = 10
  # Statuses that mean the device token will never work again.
  DEAD_REASONS = [:BadDeviceToken, :Unregistered, :DeviceTokenNotForTopic, :ExpiredToken].freeze

  Result = Struct.new(:status, :reason, :apns_id, keyword_init: true) {
    def ok? = status.to_i == 200
    def dead_token? = status.to_i == 410 || DEAD_REASONS.include?(reason&.to_sym)
  }

  MUTEX = Mutex.new

  class << self
    def configured?
      key_pem.present? && key_id.present? && team_id.present?
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

      headers = {
        "authorization"   => "bearer #{provider_token}",
        "apns-topic"      => [topic, topic_suffix].compact.join("."),
        "apns-push-type"  => push_type.to_s,
        "apns-priority"   => (priority || default_priority(push_type)).to_s,
        "apns-expiration" => (expiration || 0).to_i.to_s,
        "content-type"    => "application/json",
      }
      headers["apns-collapse-id"] = collapse_id.to_s.first(64) if collapse_id.present?
      body = payload.to_json

      if Rails.env.local? || !configured?
        log_only(token, headers, body)
        return Result.new(status: 200, reason: :Logged)
      end

      call(environment, "/3/device/#{token}", headers, body)
    end

    private

    # Background pushes must be 5; Apple drops a 10 for content-available.
    def default_priority(push_type)
      push_type.to_sym == :background ? 5 : 10
    end

    def call(environment, path, headers, body)
      env = environment.to_s == "development" ? :development : :production
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

    def provider_token
      MUTEX.synchronize {
        if @provider_token.nil? || @provider_token_at < TOKEN_TTL.ago
          key = OpenSSL::PKey::EC.new(key_pem)
          @provider_token = JWT.encode(
            { iss: team_id, iat: Time.current.to_i },
            key,
            "ES256",
            { kid: key_id },
          )
          @provider_token_at = Time.current
        end
        @provider_token
      }
    end

    # The key is stored as the .p8 file's text; an env var often carries its
    # newlines escaped.
    def key_pem
      ENV.fetch("PORTFOLIO_APNS_KEY", "").gsub("\\n", "\n").presence
    end

    def key_id = ENV.fetch("PORTFOLIO_APNS_KEY_ID", nil)
    def team_id = ENV.fetch("PORTFOLIO_APNS_TEAM_ID", nil)

    def log_only(token, headers, body)
      return if Rails.env.test?

      Rails.logger.info("[APNS][#{headers["apns-push-type"]}] #{token.to_s.first(8)}… #{body}")
    end
  end
end
