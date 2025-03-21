REAL_TESLA_ENDPOINTS = true
DEBUG_LOGGING = true

require "sinatra"

require "rest-client"

require "json"
require "coderay"

require_relative "../app/service/api.rb"

require "pry-rails"

if REAL_TESLA_ENDPOINTS
  OAUTH_BASE_URL = "https://auth.tesla.com" # no slash
  TARGET_BASE_URL = "https://localhost:8752" # no slash
else
  OAUTH_BASE_URL = "http://localhost:3141/tesla"
  TARGET_BASE_URL = "http://localhost:3141/tesla"
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
    to_s.gsub(/\s/, "").length == 0 ? nil : self
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
    self: "\e[36m",
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
      headers res.headers.transform_keys { |k| k.to_s.gsub("_", "-").upcase }
      res.body.presence || "{}"
    rescue RestClient::ExceptionWithResponse => res_exc
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[37m request:#{res_exc.response.request.url}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[31m Error\e[0m"
      response = res_exc.response
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m status: #{response.code}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m body: #{response.body}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m headers: #{response.headers.to_h}\e[0m"

      status response.code
      headers response.headers.transform_keys { |k| k.to_s.gsub("_", "-").upcase }
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
        method: :post,
        url: "#{TARGET_BASE_URL}#{request.path_info}",
        payload: data,
        headers: proxy_headers,
        ssl_ca_file: "/Users/rocco/code/Portfolio/_scripts/tesla_keys/cert.pem",
        return_full_response: true,
      )
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[32m Success\e[0m"

      status res.code
      headers res.headers.transform_keys { |k| k.to_s.gsub("_", "-").upcase }
      res.body.presence || "{}"
    rescue RestClient::ExceptionWithResponse => res_exc
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[37m request:#{res_exc.response.request.url}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[31m Error\e[0m"
      response = res_exc.response
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m status: #{response.code}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m body: #{response.body}\e[0m"
      puts "\e[90m[LOGIT:#{File.basename(__FILE__)}:#{__LINE__}]\e[33m headers: #{response.headers.to_h}\e[0m"

      status response.code
      headers response.headers.transform_keys { |k| k.to_s.gsub("_", "-").upcase }
      response.body.presence || "{}"
    end
  end
end

ProxyServer.run! if __FILE__ == $0
exit
