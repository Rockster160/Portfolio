module Teller
  # Verifies the `Teller-Signature` header on inbound webhooks.
  #
  # Header shape: `t=<unix_ts>,v1=<hex_hmac>[,v1=<hex_hmac>...]`
  # The signed message is `<t>.<raw_body>`, HMAC-SHA256 under the signing
  # secret. Teller sends several `v1` values while a secret is being rotated,
  # so any one matching is a pass.
  module Webhook
    TOLERANCE = 3.minutes

    class << self
      def verify(header, body, secret: signing_secret, now: ::Time.current)
        return false if secret.blank? || header.blank?

        timestamp, signatures = parse(header)
        return false if timestamp.zero? || signatures.empty?
        return false if (now.to_i - timestamp).abs > TOLERANCE.to_i

        expected = ::OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
        signatures.any? { |sig|
          ::ActiveSupport::SecurityUtils.secure_compare(sig, expected)
        }
      end

      def signing_secret
        ::ENV["PORTFOLIO_TELLER_SIGN_SECRET"].presence
      end

      private

      def parse(header)
        pairs = header.to_s.split(",").map { |part| part.strip.split("=", 2) }
        timestamp = pairs.find { |key, _value| key == "t" }&.last.to_i
        signatures = pairs.select { |key, value| key == "v1" && value.present? }.map(&:last)
        [timestamp, signatures]
      end
    end
  end
end
