require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

module AppStore
  class Error < StandardError; end

  # The App Store Connect API, signed with one of the team's API keys
  # (https://developer.apple.com/documentation/appstoreconnectapi). Records come
  # back as { id:, type:, attributes:, relationships: } with symbol keys.
  class Connect
    # Apple's answer to a request it refused, each problem as one line.
    class Refused < Error
      attr_reader :status, :problems

      def initialize(status, problems)
        @status = status
        @problems = problems.empty? ? ["App Store Connect answered #{status}"] : problems
        super(@problems.join("\n"))
      end
    end

    HOST = "https://api.appstoreconnect.apple.com".freeze
    # Apple refuses a token that lasts longer than 20 minutes.
    TOKEN_LIFE = 15 * 60
    TRIES = 3
    NETWORK_ERRORS = [
      IOError,
      SocketError,
      Timeout::Error,
      OpenSSL::SSL::SSLError,
      SystemCallError,
    ].freeze

    def initialize(key_id:, issuer_id:, key_path:)
      @key_id = key_id
      @issuer_id = issuer_id
      @key = OpenSSL::PKey::EC.new(File.read(key_path))
    end

    def get(path, params={}) = request(Net::HTTP::Get, path, params: params)
    def post(path, data) = request(Net::HTTP::Post, path, body: { data: data })
    def patch(path, data) = request(Net::HTTP::Patch, path, body: { data: data })

    # A new record of type; relationships are { name => link or [links] } (Connect.link).
    def create(type, attributes={}, relationships={})
      post("/v1/#{type}", payload(type, nil, attributes, relationships))[:data]
    end

    def update(type, id, attributes={}, relationships={})
      patch("/v1/#{type}/#{id}", payload(type, id, attributes, relationships))[:data]
    end

    # What a relationship points at, from a record or a type and id.
    def self.link(record_or_type, id=nil)
      return { type: record_or_type, id: id } if id

      { type: record_or_type[:type], id: record_or_type[:id] }
    end

    # The record at path, or nil when there is none.
    def record(path, params={})
      get(path, params)[:data]
    rescue Refused => e
      raise unless e.status == 404

      nil
    end

    # Every record of a list, across its pages.
    def list(path, params={})
      records = []
      answer = get(path, params)
      loop do
        records.concat(Array(answer[:data]))
        following = answer.dig(:links, :next)
        break unless following

        answer = get(following)
      end
      records
    end

    # Sends one part of a file Apple asked for (an upload operation).
    def upload(operation, bytes)
      uri = URI(operation[:url])
      kind = Net::HTTP.const_get(operation[:method].capitalize)
      request = kind.new(uri)
      Array(operation[:requestHeaders]).each { |header| request[header[:name]] = header[:value] }
      request.body = bytes.byteslice(operation[:offset], operation[:length])
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      return if response.is_a?(Net::HTTPSuccess)

      raise Refused.new(response.code.to_i, ["The upload of a file failed"])
    end

    private

    def payload(type, id, attributes, relationships)
      data = { type: type, id: id }.compact
      data[:attributes] = attributes unless attributes.empty?
      unless relationships.empty?
        data[:relationships] = relationships.transform_values { |related| { data: related } }
      end
      data
    end

    def request(kind, path, params: {}, body: nil)
      uri = URI(path.start_with?("https://") ? path : "#{HOST}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?
      tries = 0
      begin
        tries += 1
        response = send_request(kind, uri, body)
        raise Refused.new(response.code.to_i, []) if response.code.to_i >= 500 && tries < TRIES
      rescue *NETWORK_ERRORS, Refused
        raise if tries >= TRIES

        sleep(tries * 2)
        retry
      end
      answer(response)
    end

    def send_request(kind, uri, body)
      headers = { "Authorization" => "Bearer #{token}", "Accept" => "application/json" }
      request = kind.new(uri, headers)
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { |http|
        http.request(request)
      }
    end

    def answer(response)
      parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body, symbolize_names: true)
      return parsed if response.is_a?(Net::HTTPSuccess)

      problems = Array(parsed[:errors]).map { |error|
        [error[:title], error[:detail]].compact.uniq.join(": ")
      }
      raise Refused.new(response.code.to_i, problems)
    rescue JSON::ParserError
      raise Refused.new(response.code.to_i, [])
    end

    # An ES256 JWT, made again shortly before the last one runs out.
    def token
      now = Time.now.to_i
      return @token if @token && now < @token_until - 60

      @token_until = now + TOKEN_LIFE
      header = { alg: :ES256, kid: @key_id, typ: :JWT }
      claims = { iss: @issuer_id, iat: now, exp: @token_until, aud: "appstoreconnect-v1" }
      signed = [header, claims].map { |part| base64url(JSON.generate(part)) }.join(".")
      @token = "#{signed}.#{base64url(raw_signature(signed))}"
    end

    # OpenSSL signs in DER; a JWT carries the two 32-byte numbers side by side.
    def raw_signature(text)
      der = @key.sign(OpenSSL::Digest.new("SHA256"), text)
      OpenSSL::ASN1.decode(der).value.map { |number| number.value.to_s(2).rjust(32, "\0".b) }.join
    end

    def base64url(text) = Base64.urlsafe_encode64(text, padding: false)
  end
end
