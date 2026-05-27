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

  # ---- OAuth exchange (initial token grant) ----
  # After the base exchange, decode the id_token to pin this connection to
  # a specific Google account. If no GoogleAccount yet exists for that
  # email under this user, materialize one and move the freshly-stored
  # tokens out of the Cache slot into the account's columns.
  def auth(params={})
    response = super
    return response if @google_account # subsequent refresh — already bound

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

    # Clear the legacy Cache slot — we don't want stale tokens shadowing
    # the per-account ones if anyone falls back to the unbound path.
    clear_legacy_cache_tokens!

    response
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
