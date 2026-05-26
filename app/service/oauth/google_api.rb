# OAuth client for Google's Calendar API.
#
#   o = Oauth::GoogleApi.new(User.me)
#   o.auth_url            # → user clicks, authorizes
#   # callback hits /webhooks/oauth/google_api → exchanges code via from_jwt(state)
#   o.list_calendars      # CalendarList API
#   o.list_events(calendar_id, sync_token: nil)
#   o.watch_events(calendar_id, channel_id:, address:)
#   o.stop_watch(channel_id:, resource_id:)
#
# Token refresh is handled automatically by Oauth::Base — a 401 retries once
# after refreshing the access token.
class Oauth::GoogleApi < Oauth::Base
  constants(
    api_url:       "https://www.googleapis.com/calendar/v3/",
    oauth_url:     "https://accounts.google.com/o/oauth2/v2/auth",
    exchange_url:  "https://oauth2.googleapis.com/token",
    client_id:     ENV.fetch("PORTFOLIO_GCP_CLIENT_ID", nil),
    client_secret: ENV.fetch("PORTFOLIO_GCP_CLIENT_SECRET", nil),
    # `calendar` (full) per spec. Bumps to `calendar.events.readonly` once we
    # know we don't need write — but we want the option to keep open.
    scopes:        "https://www.googleapis.com/auth/calendar openid email",
    redirect_uri:  "https://ardesian.com/webhooks/oauth/google_api",
    storage_key:   :google_api,
    # Google requires `prompt=consent` to reliably return a refresh_token on
    # re-auth; `access_type=offline` (in Oauth::Base#auth_url) gets us one in
    # the first place.
    auth_params:   {
      prompt:                 :consent,
      include_granted_scopes: true,
    },
  )

  # ---- CalendarList ----

  # https://developers.google.com/calendar/api/v3/reference/calendarList/list
  def list_calendars
    get("users/me/calendarList", { maxResults: 250 })
  end

  # ---- Events ----

  # https://developers.google.com/calendar/api/v3/reference/events/list
  #
  # First sync: pass `sync_token: nil`, optional `time_min` to limit history.
  # Incremental: pass the `nextSyncToken` from the previous run.
  #
  # Google returns 410 Gone if the sync_token has expired (typically 30 days
  # of inactivity) — caller should detect and re-run a full sync.
  def list_events(calendar_id, sync_token: nil, time_min: nil, page_token: nil)
    params = {
      maxResults:   250,
      singleEvents: false, # keep recurring masters as masters
      showDeleted:  true,  # so syncToken-driven deletes flow through
    }
    if sync_token.present?
      params[:syncToken] = sync_token
    elsif time_min.present?
      params[:timeMin] = time_min.iso8601
    end
    params[:pageToken] = page_token if page_token.present?

    get("calendars/#{CGI.escape(calendar_id)}/events", params)
  end

  # ---- Push notifications (events.watch) ----

  # https://developers.google.com/calendar/api/v3/reference/events/watch
  # Returns { id, resourceId, expiration: <ms-since-epoch as string> }.
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
    return unless refresh_token.present? || access_token.present?

    token = refresh_token.presence || access_token
    Api.post("https://oauth2.googleapis.com/revoke?token=#{token}", {})
    cache.dig_set(storage_key, :access_token, nil)
    cache.dig_set(storage_key, :refresh_token, nil)
    cache.save
  end
end
