# o = Oauth::ClassApi.new(User.me, scopes: %w[user-email user-account])
# # NOTE: Careful! Some services expect scopes to be a string, others an array.
# o.client_id = "abc-123"
# o.client_secret = "321-cba"
# o.auth_url # -- click the link, authorize
# # After filling in, this will redirect and theoretically set `o.code = params[:code]`
# # After that point, things should be working!

class Oauth::Base
  # oauth_url
  # exchange_url
  # client_id
  # client_secret
  # scopes
  # redirect_uri
  # storage_key
  # auth_params
  # exchange_params

  USER_AGENT = "Jarvis-1.0"

  def self.default_service_name = name.split("::").last.underscore
  def self.defaults(service=nil)
    service ||= default_service_name
    {
      service: service,
      oauth_url: "", # First interaction - give the user this url to click/open
      exchange_url: "", # Second interaction - use the code from the first interaction to get the access_token
      api_url: "", # All future interactions: Base url for all api requests
      client_id: nil,
      client_secret: nil,
      scopes: [],
      redirect_uri: "https://ardesian.com/webhooks/oauth/#{service}",
      storage_key: service,
      auth_params: {},
      exchange_params: {},
    }
  end

  def self.constants(hash)
    @constants = hash
  end
  def self.preset_constants(service=nil)
    (@constants || {}).reverse_merge(defaults(service))
  end

  def self.from_jwt(token)
    decoded = JWT.decode(token, Rails.application.secret_key_base, true, algorithm: "HS256")
    return unless decoded.is_a?(Array) && decoded.first.is_a?(Hash)
    json = decoded.first.deep_symbolize_keys
    return unless json[:timestamp].to_i > 10.minutes.ago.to_i
    return unless json[:service].to_s == key

    user = json[:user_id].presence&.then { |id| User.find_by(id: id) }
    new(user) if user.present?
  end

  def initialize(user, overrides={})
    @_overrides = overrides # Store for serialization
    @user = user

    self.class.preset_constants(overrides[:service]).merge(overrides).each do |key, val|
      instance_variable_set("@#{key}", cache_get(key) || val)
      self.class.define_method(key.to_sym) do
        cache_get(key) || instance_variable_get("@#{key}")
      end
    end
  end

  def to_h
    @_overrides.merge(client_id: client_id, client_secret: client_secret)
  end

  def auth_url
    params = {
      response_type: :code,
      client_id: client_id,
      state: jwt,
      redirect_uri: redirect_uri,
      scope: scopes,
      access_type: :offline,
    }.merge(auth_params).compact_blank

    "#{oauth_url}?#{params.to_query}"
  end

  def code=(code)
    auth({ code: code, grant_type: :authorization_code }.merge(exchange_params)).compact_blank

    self
  end

  def cache
    @cache ||= @user.caches.by(:oauth)
  end

  def auth(params={})
    Api.post(params.delete(:exchange_url) || exchange_url, {
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      scope: scopes,
    }.merge(params), { user_agent: USER_AGENT }).tap { |json|
      next if json.nil?

      cache.skip_save_set = true
      [:access_token, :refresh_token, :id_token].each do |token_name|
        cache.dig_set(storage_key, token_name, json[token_name]) if json[token_name].present?
      end
      cache.skip_save_set = false
      cache.save
    }
  end

  def url(path, base: api_url)
    return path if path.starts_with?("http")

    [base.to_s.sub(/\/$/, ""), path.to_s.sub(/^\//, "")].join("/")
  end

  [:get, :post, :put, :patch, :delete].each do |method|
    define_method(method) do |path, params={}, headers={}, opts={}|
      request(url(path), method, params, headers, opts)
    end
  end

  def request(path, method, params={}, headers={}, opts={})
    attempt = 0
    begin
      attempt += 1
      Api.request(
        url: url(path),
        payload: params.presence || {},
        headers: base_headers.merge(headers.presence || {}),
        method: method,
        **opts,
      )
    rescue RestClient::Unauthorized
      raise if attempt > 1

      refresh
      retry
    end
  end

  def jwt
    payload = { user_id: @user.id, service: service, timestamp: Time.now.to_i, nonce: SecureRandom.hex(16) }
    JWT.encode(payload, Rails.application.secret_key_base, "HS256")
  end

  def cache_set(key, val) = cache.dig_set(@storage_key, key, val) && val
  def cache_get(key) = cache.dig(@storage_key, key)
  def access_token=(new_token)
    cache_set(:access_token, new_token)
  end
  def refresh_token=(new_token)
    cache_set(:refresh_token, new_token)
  end
  def id_token=(new_token)
    cache_set(:id_token, new_token)
  end
  def client_id=(new_token)
    @client_id = cache_set(:client_id, new_token)
  end
  def client_secret=(new_token)
    @client_secret = cache_set(:client_secret, new_token)
  end
  def access_token = cache_get(:access_token)
  def refresh_token = cache_get(:refresh_token)
  def id_token = cache_get(:id_token)

  # should have refresh_get, refresh_post

  def refresh(params={})
    auth({
      grant_type: :refresh_token,
      refresh_token: refresh_token || access_token
    }.merge(params))

    self
  end

  def base_headers(include_access_token: true)
    {
      user_agent: USER_AGENT,
      content_type: "application/json",
      Authorization: include_access_token && access_token.present? ? "Bearer #{access_token}" : nil
    }.compact_blank
  end
end
