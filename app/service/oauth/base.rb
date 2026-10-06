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

  USER_AGENT = "Jarvis-1.0".freeze

  # Kept encrypted in the user's secrets rather than the plain-JSON oauth cache,
  # which is readable on /jil/cache. Everything else (client_id, a service's own
  # bookkeeping like Venmo's contact_ids) stays in the cache.
  SECRET_FIELDS = [:client_secret, :access_token, :refresh_token, :id_token].freeze

  def self.secret_name(storage_key, field) = "oauth:#{storage_key}:#{field}"

  def self.default_service_name = name.split("::").last.underscore

  def self.defaults(service=nil)
    service ||= default_service_name
    {
      service:         service,
      oauth_url:       "", # First interaction - give the user this url to click/open
      exchange_url:    "", # Second interaction - use the code from the first interaction to get the access_token
      api_url:         "", # All future interactions: Base url for all api requests
      client_id:       nil,
      client_secret:   nil,
      scopes:          [],
      redirect_uri:    "https://ardesian.com/webhooks/oauth/#{service}",
      storage_key:     service,
      auth_params:     {},
      exchange_params: {},
    }
  end

  def self.constants(hash)
    @constants = hash
  end

  def self.preset_constants(service=nil)
    (@constants || {}).reverse_merge(defaults(service))
  end

  # Returns an Oauth instance bound to the user encoded in `token`, or nil
  # if the token is missing, malformed, expired, or for a different service.
  # Callers (e.g. webhooks#auth, anywhere using `from_jwt(...)&.code = ...`)
  # rely on this returning nil rather than raising on bad input.
  # State JWT lifetime. Google's docs don't impose a server-side TTL on
  # the `state` param — it's ours to validate. 10 minutes was too short
  # for users who walk away mid-consent or hit a "choose account" page.
  STATE_JWT_TTL = 1.hour

  def self.from_jwt(token)
    return nil if token.blank?

    decoded = JWT.decode(token, Rails.application.secret_key_base, true, algorithm: "HS256")
    return unless decoded.is_a?(Array) && decoded.first.is_a?(Hash)

    json = decoded.first.deep_symbolize_keys
    return unless json[:timestamp].to_i > STATE_JWT_TTL.ago.to_i
    return unless json[:service].to_s == default_service_name

    user = json[:user_id].presence&.then { |id| User.find_by(id: id) }
    new(user) if user.present?
  rescue JWT::DecodeError
    nil
  end

  def self.me
    new(User.me)
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

  # Carried around by Jil as the connection, so it holds no secret; the secret
  # is read back from storage on each request.
  def to_h
    @_overrides.merge(client_id: client_id)
  end

  def auth_url
    params = {
      response_type: :code,
      client_id:     client_id,
      state:         jwt,
      redirect_uri:  redirect_uri,
      scope:         scopes,
      access_type:   :offline,
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
    Api.post(
      params.delete(:exchange_url) || exchange_url, {
        client_id:     client_id,
        client_secret: client_secret,
        redirect_uri:  redirect_uri,
        scope:         scopes,
      }.merge(params), { user_agent: USER_AGENT }
    ).tap { |json|
      next if json.nil?

      [:access_token, :refresh_token, :id_token].each do |token_name|
        cache_set(token_name, json[token_name]) if json[token_name].present?
      end
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
        url:     url(path),
        payload: params.presence || {},
        headers: base_headers.merge(headers.presence || {}),
        method:  method,
        **opts,
      )
    rescue RestClient::Unauthorized
      raise if attempt > 1

      refresh
      retry
      # rescue RestClient::BadRequest => e
      # TODO: Rescue other RestClient errors and bubble up as a response
      #   raise
    end
  end

  def jwt
    payload = {
      user_id:   @user.id,
      service:   service,
      timestamp: Time.now.to_i,
      nonce:     SecureRandom.hex(16),
    }
    JWT.encode(payload, Rails.application.secret_key_base, "HS256")
  end

  def cache_set(key, val)
    return secret_set(key, val) if SECRET_FIELDS.include?(key.to_sym)

    cache.dig_set(@storage_key, key, val) && val
  end

  def cache_get(key)
    return secret_get(key) if SECRET_FIELDS.include?(key.to_sym)

    cache.dig(@storage_key, key)
  end

  # `initialize` reads every preset key before it has reached storage_key, and
  # a secret only exists under one.
  def secret_get(field)
    return nil if @storage_key.blank?

    @user.secrets.named(self.class.secret_name(@storage_key, field))&.value
  end

  def secret_set(field, val)
    name = self.class.secret_name(@storage_key, field)
    secret = @user.secrets.named(name)

    if val.blank?
      secret&.destroy!
    elsif secret.nil?
      @user.secrets.create!(name: name, value: val)
    elsif secret.value != val
      secret.update!(value: val)
    end
    val
  end

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
      grant_type:    :refresh_token,
      refresh_token: refresh_token || access_token,
    }.merge(params))

    self
  end

  def base_headers(include_access_token: true)
    {
      user_agent:    USER_AGENT,
      content_type:  "application/json",
      Authorization: include_access_token && access_token.present? ? "Bearer #{access_token}" : nil,
    }.compact_blank
  end
end
