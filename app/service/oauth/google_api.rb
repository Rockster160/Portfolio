# OAuth client for Google's Calendar API.
#
# Two construction modes:
#
#   Oauth::GoogleApi.new(user)
#     — Transient, no account yet. Used to build `auth_url` for an OAuth
#       round-trip and to handle the callback's code exchange. Tokens from
#       the exchange land in a freshly-created GoogleAccount whose email is
#       decoded from the returned id_token.
#
#   Oauth::GoogleApi.for_account(google_account)
#     — Bound to a specific user+account. Token reads/writes go through the
#       GoogleAccount row, not the legacy UserCache slot. This is what the
#       sync workers and per-calendar API calls use day-to-day.
#
# The Cache-backed path on Oauth::Base is preserved for non-first-class
# Jil OAuth integrations; we just bypass it here when an account is bound.
class Oauth::GoogleApi < Oauth::Base
  constants(
    api_url:       "https://www.googleapis.com/calendar/v3/",
    oauth_url:     "https://accounts.google.com/o/oauth2/v2/auth",
    exchange_url:  "https://oauth2.googleapis.com/token",
    client_id:     ENV.fetch("PORTFOLIO_GCP_CLIENT_ID", nil),
    client_secret: ENV.fetch("PORTFOLIO_GCP_CLIENT_SECRET", nil),
    scopes:        "https://www.googleapis.com/auth/calendar openid email",
    redirect_uri:  "https://ardesian.com/webhooks/oauth/google_api",
    storage_key:   :google_api,
    # `prompt=consent` ensures we get a refresh_token on every authorization
    # (Google omits it on subsequent consents otherwise). `select_account`
    # lets a user pick a DIFFERENT Google account on re-auth — required for
    # the multi-account flow.
    auth_params:   {
      prompt:                 "consent select_account",
      include_granted_scopes: true,
    },
  )

  attr_accessor :google_account

  def self.for_account(google_account)
    new(google_account.user).tap { |api| api.google_account = google_account }
  end

  # ---- Token storage ----
  # When bound to a GoogleAccount, read/write tokens on its row directly.
  # When unbound (during the initial OAuth round-trip), fall back to the
  # Cache-backed default so super's `auth` can still stash the tokens we'll
  # then move into a freshly-created GoogleAccount.

  def access_token
    @google_account ? @google_account.access_token : super
  end

  def refresh_token
    @google_account ? @google_account.refresh_token : super
  end

  def id_token
    @google_account ? @google_account.id_token : super
  end

  def access_token=(value)
    if @google_account
      @google_account.update!(access_token: value, tokens_refreshed_at: ::Time.current)
    else
      super
    end
  end

  def refresh_token=(value)
    if @google_account
      # Google sometimes omits refresh_token on a refresh; keep the old one.
      @google_account.update!(refresh_token: value) if value.present?
    else
      super
    end
  end

  def id_token=(value)
    if @google_account
      @google_account.update!(id_token: value)
    else
      super
    end
  end

  # ---- OAuth exchange (initial token grant + refreshes) ----
  #
  # When @google_account is already set (we're refreshing an existing
  # connection), we make the token-endpoint POST ourselves and write the
  # response back to the account's columns. Otherwise Oauth::Base#auth
  # would write the new tokens to the legacy UserCache slot — and our
  # access_token override would keep reading the stale value from the
  # GoogleAccount, looping 401→refresh→401 until quota burns.
  #
  # On 400 invalid_grant (refresh_token revoked/expired), mark the bound
  # account `reauth_required` and return nil rather than bubbling 400.
  def auth(params={})
    return refresh_bound_account!(params) if @google_account

    response = super
    email = email_from_id_token(response&.dig(:id_token) || response&.dig("id_token"))
    return response if email.blank?

    account = @user.google_accounts.find_or_initialize_by(email: email)
    account.access_token = response[:access_token] || response["access_token"] || account.access_token
    account.refresh_token = response[:refresh_token] || response["refresh_token"] || account.refresh_token
    account.id_token = response[:id_token] || response["id_token"] || account.id_token
    account.tokens_refreshed_at = ::Time.current
    account.reauth_required_at = nil
    account.save!
    @google_account = account
    clear_legacy_cache_tokens!

    response
  rescue ::RestClient::BadRequest => e
    @google_account&.mark_reauth_required!
    ::Rails.logger.warn("[Oauth::GoogleApi] auth failed account=#{@google_account&.id} #{e.class}: #{e.message}")
    nil
  end

  # ---- API surface ----
  # https://developers.google.com/calendar/api/v3/reference/calendarList/list
  def list_calendars
    get("users/me/calendarList", { maxResults: 250 })
  end

  # https://developers.google.com/calendar/api/v3/reference/events/list
  def list_events(calendar_id, sync_token: nil, time_min: nil, page_token: nil)
    params = { maxResults: 250, singleEvents: false, showDeleted: true }
    if sync_token.present?
      params[:syncToken] = sync_token
    elsif time_min.present?
      params[:timeMin] = time_min.iso8601
    end
    params[:pageToken] = page_token if page_token.present?

    get("calendars/#{CGI.escape(calendar_id)}/events", params)
  end

  # https://developers.google.com/calendar/api/v3/reference/events/watch
  def watch_events(calendar_id, channel_id:, address:, token: nil, ttl_seconds: 7.days.to_i)
    body = {
      id:      channel_id,
      type:    :web_hook,
      address: address,
      params:  { ttl: ttl_seconds.to_s },
    }
    body[:token] = token if token.present?
    post("calendars/#{CGI.escape(calendar_id)}/events/watch", body)
  end

  # https://developers.google.com/calendar/api/v3/reference/channels/stop
  def stop_watch(channel_id:, resource_id:)
    post("channels/stop", { id: channel_id, resourceId: resource_id })
  end

  # https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke
  def revoke!
    token = refresh_token.presence || access_token
    return if token.blank?

    Api.post("https://oauth2.googleapis.com/revoke?token=#{token}", {})
    if @google_account
      @google_account.update!(access_token: nil, refresh_token: nil, id_token: nil)
    else
      cache.dig_set(storage_key, :access_token, nil)
      cache.dig_set(storage_key, :refresh_token, nil)
      cache.save
    end
  end

  private

  # Bound-refresh: POST to the token endpoint ourselves so we can write the
  # response directly into the GoogleAccount columns. Bypasses Oauth::Base's
  # cache writes which would otherwise leave stale tokens shadowing the
  # account's row.
  def refresh_bound_account!(params)
    response = ::Api.post(
      params.delete(:exchange_url) || exchange_url,
      {
        client_id:     client_id,
        client_secret: client_secret,
        redirect_uri:  redirect_uri,
        scope:         scopes,
      }.merge(params),
      { user_agent: USER_AGENT },
    )
    return nil if response.nil?

    @google_account.update!({
      access_token:        response[:access_token].presence || @google_account.access_token,
      # Google typically omits refresh_token on a refresh — keep the old one.
      refresh_token:       response[:refresh_token].presence || @google_account.refresh_token,
      id_token:            response[:id_token].presence || @google_account.id_token,
      tokens_refreshed_at: ::Time.current,
      reauth_required_at:  nil,
    })
    response
  end

  # Google's id_token is a signed JWT; we trust it because Google signed the
  # exchange response over TLS to our redirect URI. Decode without
  # verifying the signature — the email claim is what we need.
  def email_from_id_token(token)
    return nil if token.blank?

    payload, _header = JWT.decode(token, nil, false)
    payload["email"]&.downcase
  rescue ::JWT::DecodeError
    nil
  end

  def clear_legacy_cache_tokens!
    cache.dig_set(storage_key, :access_token, nil)
    cache.dig_set(storage_key, :refresh_token, nil)
    cache.dig_set(storage_key, :id_token, nil)
    cache.save
  rescue StandardError
    # Cache cleanup is best-effort; failing it shouldn't break the OAuth flow.
  end
end
