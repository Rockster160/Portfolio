require "net/http"
require "json"
require "uri"

# Rails → local Mac server bridge for Byte. Keeps the HTTP call site
# in one place so we can swap transports (worker, queue, tunnel) without
# touching the controller.
#
# Config via env:
#   BYTE_LOCAL_URL     — base URL of the Mac server (default localhost:8788)
#   BYTE_LOCAL_SECRET  — shared secret; sent as X-Byte-Secret header
module ByteLocal
  module_function

  DEFAULT_URL = "http://localhost:8788".freeze
  DEFAULT_PORT = 8788
  TIMEOUT_SECONDS = 5

  # Resolution order:
  # 1. `BYTE_LOCAL_URL` — explicit override for staging / tunnels
  # 2. `DataStorage[:local_ip]` — auto-detected Mac public IP, refreshed by
  #    the `webhooks/local_ping` job (same source Tesla uses; requires port
  #    #{DEFAULT_PORT} forwarded on the router to the Mac's LAN IP)
  # 3. `localhost:8788` — dev fallback (Rails and the Mac server share a host)
  def base_url
    return ENV["BYTE_LOCAL_URL"] if ENV["BYTE_LOCAL_URL"].present?

    ip = ::DataStorage[:local_ip]
    return "http://#{ip}:#{DEFAULT_PORT}" if ip.present?

    DEFAULT_URL
  end

  def secret
    ENV.fetch("BYTE_LOCAL_SECRET", "")
  end

  # Kick off downstream handling for a user-sent message. Non-blocking as
  # far as the caller cares: the local server is expected to accept the
  # request quickly and stream a response back via /webhooks/byte.
  def deliver(message)
    uri = URI.join(base_url, "/byte/incoming")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "X-Byte-Secret" => secret)
    req.body = JSON.generate({
      message_id: message.id,
      user_id:    message.user_id,
      body:       message.body,
      metadata:   message.metadata,
    })

    Net::HTTP.start(uri.hostname, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS,
    ) { |http|
      http.request(req)
    }
  rescue => e
    Rails.logger.warn("[Byte] local deliver failed: #{e.class}: #{e.message}")
    nil
  end

  def valid_secret?(header_value)
    expected = secret
    return true if expected.empty? && Rails.env.development?

    header_value.present? && ActiveSupport::SecurityUtils.secure_compare(header_value.to_s, expected)
  end
end
