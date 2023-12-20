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

  def initialize(user)
    @user = user
  end

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

  def cache
    @cache ||= @user.cache
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
      cache.skip_save_set = true
      [:access_token, :refresh_token, :id_token].each do |token_name|
        cache.dig_set(:oauth, STORAGE_KEY, token_name, json[token_name]) if json[token_name].present?
      end
      cache.skip_save_set = false
      cache.save
    }
  end

  def url(path, base: API_URL)
    [base.to_s.sub(/\/$/, ""), path.to_s.sub(/^\//, "")].join("/")
  end

  def get(path, params={}, headers={})
    Api.get(url(path), params, base_headers.merge(headers))
  end

  def post(path, params={}, headers={})
    Api.get(url(path), params, base_headers.merge(headers))
  end

  def access_token=(new_token) = cache.dig_set(:oauth, STORAGE_KEY, :access_token, new_token)
  def refresh_token=(new_token) = cache.dig_set(:oauth, STORAGE_KEY, :refresh_token, new_token)
  def id_token=(new_token) = cache.dig_set(:oauth, STORAGE_KEY, :id_token, new_token)
  def access_token = cache.dig(:oauth, STORAGE_KEY, :access_token)
  def refresh_token = cache.dig(:oauth, STORAGE_KEY, :refresh_token)
  def id_token = cache.dig(:oauth, STORAGE_KEY, :id_token)

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
