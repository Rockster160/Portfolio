# OAuth client for Google's Calendar API.
#
# Two construction modes:
#
#   Oauth::GoogleApi.new(user)
#     — Transient, used only between `auth_url` and the OAuth callback's
#       code-exchange. After the exchange, `auth` materializes a
#       GoogleAccount from the id_token's email and binds itself to it.
#
#   Oauth::GoogleApi.for_account(google_account)
#     — Bound to a specific user+account. Every API call (and the auto-
#       refresh on 401) reads/writes tokens against the GoogleAccount row.
#
# Tokens are NEVER stored in the legacy UserCache slot. The base class
# `Oauth::Base#auth` would do that — we override `auth` entirely so it
# never runs, and write directly to the GoogleAccount columns.
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
    auth_params:   {
      prompt:                 "consent select_account",
      include_granted_scopes: true,
    },
  )

  attr_accessor :google_account

  def self.for_account(google_account)
    new(google_account.user).tap { |api| api.google_account = google_account }
  end

  def initialize(user, overrides={})
    super
    return unless ::Rails.env.production?
    return if @client_id.present? && @client_secret.present?

    # Defense in depth: missing creds will eventually 400 against Google.
    # Surface it via Slack on the first runtime use rather than letting
    # the user hit a vague OAuth error and dig through Sidekiq logs.
    self.class.notify_missing_credentials!
  end

  # Slack-notify once per process so we don't spam on every API call.
  def self.notify_missing_credentials!
    return if @missing_creds_notified

    @missing_creds_notified = true
    ::SlackNotifier.notify(
      "PORTFOLIO_GCP_CLIENT_ID/SECRET is unset on production — Google Calendar OAuth will fail. " \
      "Set the env vars and restart Puma.",
    )
  rescue StandardError
    # Slack itself failing shouldn't break OAuth setup.
  end

  # ---- Token accessors (account-backed) ----

  def access_token
    @google_account&.access_token
  end

  def refresh_token
    @google_account&.refresh_token
  end

  def id_token
    @google_account&.id_token
  end

  def access_token=(value)
    @google_account.update!(access_token: value, tokens_refreshed_at: ::Time.current)
  end

  def refresh_token=(value)
    # Google often omits refresh_token on a refresh — keep the old one.
    return if value.blank?

    @google_account.update!(refresh_token: value)
  end

  def id_token=(value)
    @google_account.update!(id_token: value)
  end

  # ---- Token exchange / refresh ----
  #
  # Overrides Oauth::Base#auth so we never touch the legacy UserCache slot.
  # Handles both:
  #   * Initial code-grant: materialize a GoogleAccount from the id_token's
  #     email, then save tokens onto it.
  #   * Refresh-token grant on a bound account: update the row in place.
  #
  # On 400 invalid_grant (refresh_token revoked or expired), flag the
  # account as needs_reauth and return nil instead of bubbling the 400 up
  # to the UI or a Sidekiq job.
  def auth(params={})
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

    account = @google_account || materialize_account_from_response(response)
    return response if account.nil? # initial flow with no decodable email — extremely rare

    account.update!(
      access_token:        response[:access_token].presence || account.access_token,
      refresh_token:       response[:refresh_token].presence || account.refresh_token,
      id_token:            response[:id_token].presence || account.id_token,
      tokens_refreshed_at: ::Time.current,
      reauth_required_at:  nil,
      # Clear the soft-disconnect tombstone — a successful reauth means the
      # picker should treat this account as live again, not stuck showing a
      # "reconnect" prompt forever.
      disconnected_at:     nil,
    )
    @google_account = account
    response
  rescue ::RestClient::BadRequest => e
    @google_account&.mark_reauth_required!
    ::Rails.logger.warn("[Oauth::GoogleApi] auth failed account=#{@google_account&.id} #{e.class}: #{e.message}")
    nil
  end

  # ---- API surface ----

  def list_calendars
    get("users/me/calendarList", { maxResults: 250 })
  end

  # Single-calendar metadata fetch. Used by the sync service to lazily
  # populate `agendas.timezone` after a connect — without this, all-day
  # event parsing has no idea what wall-clock zone "May 28" lives in.
  def get_calendar(calendar_id)
    get("calendars/#{CGI.escape(calendar_id)}")
  end

  # PATCH the calendar metadata. Lets owners rename or recolor a Google
  # calendar from our UI and have the change propagate upstream rather
  # than silently diverging. Only the calendar's owner can patch.
  def patch_calendar(calendar_id, body)
    request(
      url("calendars/#{CGI.escape(calendar_id)}"),
      :patch,
      body,
    )
  end

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

  # Resolve the authoritative instance id for a single occurrence of a
  # recurring event. Google's id format varies by event type / source TZ
  # (`{master}_YYYYMMDD` for all-day, `{master}_YYYYMMDDTHHMMSSZ` for
  # timed, sometimes with non-UTC offsets) — synthesizing it client-side
  # is fragile. This endpoint returns the real ids in the requested window.
  def list_event_instances(calendar_id, event_id, time_min:, time_max:)
    get(
      "calendars/#{CGI.escape(calendar_id)}/events/#{CGI.escape(event_id)}/instances",
      {
        timeMin:     time_min.iso8601,
        timeMax:     time_max.iso8601,
        maxResults:  10,
        showDeleted: false,
      },
    )
  end

  # ---- Event write-back ----
  # PATCH/DELETE/POST so user edits in our UI propagate to Google.

  def patch_event(calendar_id, event_id, body)
    request(
      url("calendars/#{CGI.escape(calendar_id)}/events/#{CGI.escape(event_id)}"),
      :patch,
      body,
    )
  end

  def delete_event(calendar_id, event_id)
    request(
      url("calendars/#{CGI.escape(calendar_id)}/events/#{CGI.escape(event_id)}"),
      :delete,
    )
  end

  def insert_event(calendar_id, body)
    post("calendars/#{CGI.escape(calendar_id)}/events", body)
  end

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

  def stop_watch(channel_id:, resource_id:)
    post("channels/stop", { id: channel_id, resourceId: resource_id })
  end

  # https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke
  def revoke!
    return if @google_account.nil?

    token = @google_account.refresh_token.presence || @google_account.access_token
    return if token.blank?

    Api.post("https://oauth2.googleapis.com/revoke?token=#{token}", {})
    @google_account.update!(access_token: nil, refresh_token: nil, id_token: nil)
  end

  private

  def materialize_account_from_response(response)
    email = email_from_id_token(response[:id_token])
    return nil if email.blank?

    @user.google_accounts.find_or_initialize_by(email: email)
  end

  # Google's id_token is a signed JWT delivered to us over TLS — we trust
  # it without verifying the signature. We only need the email claim.
  def email_from_id_token(token)
    return nil if token.blank?

    payload, _header = JWT.decode(token, nil, false)
    payload["email"]&.downcase
  rescue ::JWT::DecodeError
    nil
  end
end
