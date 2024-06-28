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

  def self.key = name.split("::").last.underscore
  def self.defaults
    {
      oauth_url: "",
      exchange_url: "",
      client_id: nil,
      client_secret: nil,
      scopes: [],
      redirect_uri: "https://ardesian.com/webhooks/oauth/#{key}",
      storage_key: key,
      auth_params: {},
      exchange_params: {},
    }
  end

  def self.constants(hash)
    @constants = hash
  end
  def self.preset_constants
    (@constants || {}).reverse_merge(defaults)
  end

  def initialize(user, overrides={})
    self.class.preset_constants.merge(overrides).each do |key, val|
      instance_variable_set("@#{key}", val)
      self.class.define_method(key.to_sym) do
        instance_variable_get("@#{key}")
      end
    end
    @user = user
  end

  def auth_url
    params = {
      response_type: :code,
      client_id: @client_id,
      redirect_uri: @redirect_uri,
      scope: @scopes,
      access_type: :offline,
    }.merge(@auth_params).compact_blank

    "#{@oauth_url}?#{params.to_query}"
  end

  def code=(code)
    auth({ code: code, grant_type: :authorization_code }.merge(@exchange_params)).compact_blank

    self
  end

  def cache
    @cache ||= @user.caches.by(:oauth)
  end

  def auth(params={})
    Api.post(params.delete(:exchange_url) || @exchange_url, {
      client_id: @client_id,
      client_secret: @client_secret,
      redirect_uri: @redirect_uri,
      scope: @scopes,
    }.merge(params), { user_agent: USER_AGENT }).tap { |json|
      next if json.nil?

      cache.skip_save_set = true
      [:access_token, :refresh_token, :id_token].each do |token_name|
        cache.dig_set(@storage_key, token_name, json[token_name]) if json[token_name].present?
      end
      cache.skip_save_set = false
      cache.save
    }
  end

  def url(path, base: @api_url)
    return path if path.starts_with?("http")

    [base.to_s.sub(/\/$/, ""), path.to_s.sub(/^\//, "")].join("/")
  end

  def get(path, params={}, headers={}, opts={})
    Api.get(url(path), params, base_headers.merge(headers), opts)
  end

  def post(path, params={}, headers={}, opts={})
    Api.post(url(path), params, base_headers.merge(headers), opts)
  end

  def cache_set(key, val) = cache.dig_set(@storage_key, key, val)
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
