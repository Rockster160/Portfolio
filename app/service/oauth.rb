class Oauth
  def self.constants(hash)
    hash.each { |ckey, cval| Oauth.const_set(ckey, cval) }
    # @constants = (@constants || {}).merge(hash)
  end

  class << self
    def url
      params = {
        response_type: :code,
        client_id: CLIENT_ID,
        redirect_uri: REDIRECT_URI,
        scope: "https://www.googleapis.com/auth/calendar.events", #,https://www.googleapis.com/auth/calendar.settings.readonly #https://www.googleapis.com/auth/calendar
        access_type: :offline,
      }

      "#{OAUTH_URL}?#{params.to_query}"
    end

    def code=(code)
      auth(
        grant_type: :authorization_code,
        code: code
      )

      self
    end

    def auth(code, params={})
      API.post(TOKEN_URL, {
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
        redirect_uri: REDIRECT_URI
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
