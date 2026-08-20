REAL_TESLA_ENDPOINTS = true
DEBUG_LOGGING = true

require "sinatra"

require "rest-client"

require "json"
require "coderay"

# Api uses Rails' `delegate`. The listener boots without full Rails so we
# pull the one ActiveSupport extension that provides it.
require "active_support/core_ext/module/delegation"

require_relative "../app/service/api"

require "pry-rails"

if REAL_TESLA_ENDPOINTS
  OAUTH_BASE_URL = "https://auth.tesla.com".freeze # no slash
  TARGET_BASE_URL = "https://localhost:8752".freeze # no slash
else
  OAUTH_BASE_URL = "http://localhost:3141/tesla".freeze
  TARGET_BASE_URL = "http://localhost:3141/tesla".freeze
end

# Create a Rails-like object for the API to define whether to show debugging
Rails = Object.new.tap { |obj|
  def obj.env
    Object.new.tap { |env|
      def env.production?
        !DEBUG_LOGGING
      end
    }
  end
}
class String
  def presence
    to_s.gsub(/\s/, "").empty? ? nil : self
  rescue ArgumentError
    self
  end
end

# https://github.com/rubychan/coderay/blob/master/lib/coderay/encoders/terminal.rb
termoverrides = {
  string: {
    self:      "\e[32m",
    modifier:  "\e[1;32m",
    char:      "\e[1;33m",
    delimiter: "\e[1;32m",
    escape:    "\e[1;32m",
  },
  symbol: {
    self:      "\e[36m",
    delimiter: "\e[1;36m",
  },
  # attribute_name: "\e[36m",
  # decorator: "\e[36m",
}
termoverrides.each do |key, val|
  ::CodeRay::Encoders::Terminal::TOKEN_COLORS[key] = val
end

class ProxyServer < Sinatra::Base
  set :port, 3142
  set :bind, "0.0.0.0"

  before do
    # define routes to skip
    pass if request.path_info == "/favicon.ico"
    # pass if !request.path_info.start_with?("/api/1")
  end

  post "/test" do
    puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m Test Received \e[36m#{request.ip}\e[0m"

    { success: true }.to_json
  end

  post "/tesla_refresh" do
    puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m #{params}\e[0m"
    puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[36mREFRESH\e[0m"
    begin
      proxy_url = "#{OAUTH_BASE_URL}/oauth2/v3/token"
      res = Api.post(proxy_url, params, {}, { return_full_response: true })

      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[32m Success\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m | #{res}\e[0m"
      status res.code
      headers(res.headers.transform_keys { |k| k.to_s.gsub("_", "-").upcase })
      res.body.presence || "{}"
    rescue RestClient::ExceptionWithResponse => e
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[37m request:#{e.response.request.url}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[31m Error\e[0m"
      response = e.response
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m status: #{response.code}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m body: #{response.body}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m headers: #{response.headers.to_h}\e[0m"

      status response.code
      headers(response.headers.transform_keys { |k| k.to_s.gsub("_", "-").upcase })
      response.body.presence || "{}"
    end
  end

  post "/api/1/*" do
    data = request.body.read
    proxy_headers = request.env.slice("CONTENT_TYPE")
    request.env.each do |key, value|
      puts "\e[36m#{key}:\e[33m #{value}\e[0m"
      proxy_headers[key.gsub(/^HTTP_/, "")] = value if key.start_with?("HTTP_")
    end
    proxy_headers = proxy_headers.transform_keys { |k| k.to_s.gsub("_", "-").upcase }

    begin
      res = Api.request(
        method:               :post,
        url:                  "#{TARGET_BASE_URL}#{request.path_info}",
        payload:              data,
        headers:              proxy_headers,
        # cert.pem is CN=localhost with no SAN; modern OpenSSL rejects that
        # during hostname verification (silent EOF on the proxy side). The
        # connection is loopback-only — TLS verification adds no security
        # over the implicit "same host" trust boundary.
        verify_ssl:           false,
        return_full_response: true,
      )
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[32m Success\e[0m"

      status res.code
      headers(res.headers.transform_keys { |k| k.to_s.gsub("_", "-").upcase })
      res.body.presence || "{}"
    rescue RestClient::ExceptionWithResponse => e
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[37m request:#{e.response.request.url}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[31m Error\e[0m"
      response = e.response
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m status: #{response.code}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m body: #{response.body}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m headers: #{response.headers.to_h}\e[0m"

      status response.code
      headers(response.headers.transform_keys { |k| k.to_s.gsub("_", "-").upcase })
      response.body.presence || "{}"
    end
  end
end

# ── Relay heartbeat ─────────────────────────────────────────────────────────
# This process is running exactly when the relay is reachable, so its own
# check-in is the one signal that separates "Mac asleep / relay dead" from
# "Mac fine, router mis-forwarding". From prod those two are indistinguishable
# — both are just a dead port — which is why every proxy alert had to list a
# sleeping Mac as a maybe and could never rule it out.

HEARTBEAT_INTERVAL = 120
HEARTBEAT_URLS = [
  "https://ardesian.com/webhooks/proxy_heartbeat",
  "http://localhost:3141/webhooks/proxy_heartbeat",
].freeze

# launchd hands this process almost no environment — the plist sets RBENV_ROOT
# and PATH and nothing else — so PORTFOLIO_AUTH has to come from the login
# shell that defines it. The sibling dashboard job solves the same problem the
# same way.
def heartbeat_auth
  auth = ENV["PORTFOLIO_AUTH"].to_s.strip
  auth = `zsh -lc 'printf %s "$PORTFOLIO_AUTH"'`.strip if auth.empty?
  auth.empty? ? nil : auth
rescue StandardError
  nil
end

def start_heartbeat
  auth = heartbeat_auth
  if auth.nil?
    puts "\e[31m[HEARTBEAT] PORTFOLIO_AUTH unavailable — relay check-ins disabled\e[0m"
    return
  end

  Thread.new do
    loop do
      HEARTBEAT_URLS.each do |url|
        RestClient.post(url, {}, { Authorization: "Basic #{auth}" })
      rescue StandardError => e
        puts "\e[90m[HEARTBEAT]\e[31m #{url} → #{e.class}\e[0m" unless url.include?("localhost")
      end
      sleep HEARTBEAT_INTERVAL
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  start_heartbeat
  ProxyServer.run!
end
exit
