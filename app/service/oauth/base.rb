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
    def auth_url
      params = {
        response_type: :code,
        client_id: CLIENT_ID,
        redirect_uri: REDIRECT_URI,
        scope: SCOPES,
        access_type: :offline,
      }.merge(AUTH_PARAMS)

      "#{OAUTH_URL}?#{params.to_query}"
    end

    def code=(code)
      auth({ code: code, grant_type: :authorization_code }.merge(EXCHANGE_PARAMS))

      self
    end

    def auth(code, params={})
      # Should be given a user to pull the cache keys from
      Api.post(EXCHANGE_URL, {
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
        redirect_uri: REDIRECT_URI,
        scope: SCOPES,
      }.merge(params)).tap { |json|
        next if json.nil?
        # puts "\e[36m[LOGIT] | #{json}\e[0m"
        current_user.jarvis_cache
        DataStorage["#{STORAGE_KEY}_access_token"] = json[:access_token] if json[:access_token].present?
        DataStorage["#{STORAGE_KEY}_refresh_token"] = json[:refresh_token] if json[:refresh_token].present?
        DataStorage["#{STORAGE_KEY}_id_token"] = json[:id_token] if json[:id_token].present?
      }
    end

    def url(path, base: API_URL)
      [base.to_s.sub(/\/$/, ""), path.to_s.sub(/^\//, "")].join("/")
    end

    def get(path, params={}, headers={})
      API.get(url(path), params, base_headers.merge(headers))
    end

    def post(path, params={}, headers={})
      API.get(url(path), params, base_headers.merge(headers))
    end

    def access_token=(new_token)
      DataStorage["#{STORAGE_KEY}_access_token"] = new_token
    end

    def refresh_token=(new_token)
      DataStorage["#{STORAGE_KEY}_refresh_token"] = new_token
    end

    def id_token=(new_token)
      DataStorage["#{STORAGE_KEY}_id_token"] = new_token
    end

    def access_token
      DataStorage["#{STORAGE_KEY}_access_token"]
    end

    def refresh_token
      DataStorage["#{STORAGE_KEY}_refresh_token"]
    end

    def id_token
      DataStorage["#{STORAGE_KEY}_id_token"]
    end

    # should have refresh_get, refresh_post

    def refresh
      auth(
        grant_type: :refresh_token,
        refresh_token: refresh_token || access_token
      )

      self
    end

    def base_headers
      {
        content_type: "application/json",
        Authorization: "Bearer #{access_token}"
      }
    end
  end
end
