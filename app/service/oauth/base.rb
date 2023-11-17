class Oauth::Base
  # CLIENT_ID
  # REDIRECT_URI
  # SCOPES
  # OAUTH_URL
  # EXCHANGE_URL
  # CLIENT_ID
  # CLIENT_SECRET
  # REDIRECT_URI
  # STORAGE_KEY

  def self.constants(hash)
    hash.each { |ckey, cval| Oauth::Base.const_set(ckey, cval) }
    # @constants = (@constants || {}).merge(hash)
  end

  class << self
    def url
      params = {
        response_type: :code,
        client_id: CLIENT_ID,
        redirect_uri: REDIRECT_URI,
        scope: Array.wrap(SCOPES).join(" "),
        access_type: :offline,
      }.merge(AUTH_PARAMS)

      "#{OAUTH_URL}?#{params.to_query}"
    end

    def code=(code)
      auth(code, { grant_type: :authorization_code }.merge(EXCHANGE_PARAMS))

      self
    end

    def auth(code, params={})
      API.post(EXCHANGE_URL, {
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
        redirect_uri: REDIRECT_URI,
        scope: SCOPES,
      }.merge(params)).tap { |json|
        next if json.nil?
        puts "\e[36m[LOGIT] | #{json}\e[0m"
        DataStorage["#{STORAGE_KEY}_access_token"] = json[:access_token] if json[:access_token].present?
        DataStorage["#{STORAGE_KEY}_refresh_token"] = json[:refresh_token] if json[:refresh_token].present?
      }
      # .tap { |res|
      #   puts "  > #{res&.body.presence || res}"
      # }
    end

    def refresh
      auth(
        grant_type: :refresh_token,
        refresh_token: DataStorage["#{STORAGE_KEY}_refresh_token"]
      )

      self
    end
  end
end
