require "sinatra"

require "uri"
require "net/http"

require "json"
require "coderay"

require_relative "../app/service/api.rb"

TARGET_BASE_URL = "https://localhost:8752" # no slash
DEBUG_LOGGING = true
# Create a Rails-like object for the API to define whether to show debugging
Rails = Object.new.tap { |obj|
  def obj.env
    Object.new.tap { |env|
      def env.production?
        DEBUG_LOGGING
      end
    }
  end
}

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
    pass if !request.path_info.start_with?("/api/1")
  end

  post "/api/1/*" do
    data = request.body.read
    headers = request.env.slice("CONTENT_TYPE")
    request.env.each do |key, value|
      # puts "\e[36m#{key}:\e[33m #{value}\e[0m"
      headers[key] = value if key.start_with?("HTTP_")
    end

    begin
      res = Api.request(
        method: :post,
        url: "#{TARGET_BASE_URL}/api/1/#{request.path_info}",
        payload: payload,
        headers: base_headers.merge(headers),
        ssl_ca_file: "/home/rocco/tesla_keys/cert.pem",
        return_full_response: true,
      )

      status res.code
      headers res.headers
      body res.body
    rescue RestClient::ExceptionWithResponse => res_exc
      response = res_exc.response
      status response.code
      headers response.headers
      body response.body
    end
  end
end

ProxyServer.run! if __FILE__ == $0
exit
