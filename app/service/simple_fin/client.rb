module SimpleFin
  # Transport for the SimpleFIN Bridge.
  #
  # The access URL carries HTTP Basic credentials inline
  # (`scheme://user:pass@host/path`) and is the entire configuration — no app
  # id, no certificate, no runtime token exchange. Claiming the one-time setup
  # token happens by hand, out of band, and yields that URL.
  #
  # Callers MUST check `errlist` on the response. A 200 can carry partial data:
  # one institution failing to refresh still returns the other accounts, with
  # the failure described there and a stale `balance-date` on whatever didn't
  # update. Treating a 200 as "all balances are current" reports stale numbers
  # as fresh ones.
  #
  # https://www.simplefin.org/protocol.html
  module Client
    # The Bridge is built for daily-ish polling: 24 requests/day is the stated
    # budget and a single /accounts range is capped at 90 days. Backfills have
    # to walk the range in chunks rather than asking for everything at once.
    MAX_RANGE_DAYS = 90
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30
    # v2 is what `errlist` and `connections` belong to; without it the Bridge
    # answers in the pre-2.0 shape that reports errors as bare strings.
    API_VERSION = 2

    Error = Class.new(StandardError)
    NotConfigured = Class.new(Error)
    RangeTooWide = Class.new(Error)

    class << self
      def accounts(balances_only: false, pending: false, start_date: nil, end_date: nil, account_ids: [])
        if start_date && end_date && (end_date.to_i - start_date.to_i) > MAX_RANGE_DAYS.days.to_i
          raise RangeTooWide, "SimpleFIN caps /accounts at #{MAX_RANGE_DAYS} days per request"
        end

        pairs = query_pairs(
          balances_only:, pending:, start_date:, end_date:, account_ids:,
        )
        get(:accounts, pairs)
      end

      def configured?
        access_url.present?
      end

      private

      def access_url
        ::ENV["PORTFOLIO_SIMPLEFIN_ACCESS_URL"].presence
      end

      def get(resource, pairs)
        uri = access_uri
        uri.path = "#{uri.path.chomp("/")}/#{resource}"
        uri.query = ::URI.encode_www_form(pairs)

        response = perform(uri)
        unless response.is_a?(::Net::HTTPSuccess)
          raise Error, "SimpleFIN #{resource} returned #{response.code}"
        end

        ::JSON.parse(response.body)
      end

      def perform(uri)
        ::Net::HTTP.start(
          uri.hostname, uri.port,
          use_ssl:      uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT
        ) { |http|
          request = ::Net::HTTP::Get.new(uri.request_uri)
          request.basic_auth(*credentials(uri))
          http.request(request)
        }
      end

      def access_uri
        raise NotConfigured, "PORTFOLIO_SIMPLEFIN_ACCESS_URL is not set" if access_url.blank?

        ::URI.parse(access_url)
      end

      # Percent-decoding only. CGI.unescape would also turn a literal `+` in
      # the password into a space, which silently breaks auth.
      def credentials(uri)
        [uri.user, uri.password].map { |part|
          ::URI::DEFAULT_PARSER.unescape(part.to_s)
        }
      end

      # `account` is repeatable, so the query is built as pairs rather than a
      # hash. Flags are presence-only: SimpleFIN reads `balances-only=1`, and
      # sending `0` still counts as asking for it.
      def query_pairs(balances_only:, pending:, start_date:, end_date:, account_ids:)
        pairs = [[:version, API_VERSION]]
        pairs << ["balances-only", 1] if balances_only
        pairs << [:pending, 1] if pending
        pairs << ["start-date", start_date.to_i] if start_date
        pairs << ["end-date", end_date.to_i] if end_date
        ::Array.wrap(account_ids).each { |id| pairs << [:account, id] }
        pairs
      end
    end
  end
end
