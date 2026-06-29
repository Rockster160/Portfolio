# https://github.com/teslamotors/vehicle-command?tab=readme-ov-file#sending-commands-to-the-proxy-server

# ### Obtain a Partner Authentication Token
# https://developer.tesla.com/docs/fleet-api#partner-authentication-token
# o = ::Oauth::TeslaApi.new(User.me)
# partner_response = o.post("https://auth.tesla.com/oauth2/v3/token", {
#   grant_type: :client_credentials,
#   client_id: o.client_id,
#   client_secret: o.client_secret,
#   scope: o.scopes,
#   audience: "https://fleet-api.prd.na.vn.cloud.tesla.com"
# })

# ### Obtain a Third-Party Token
# o.auth_url
# <auto sets the code via webhook and makes the post-request to Tesla and updated the credentials>
# o.code = params[:code]

# https://developer.tesla.com/docs/fleet-api#public_key
# o.post(:partner_accounts, { domain: "ardesian.com" }, { Authorization: "Bearer #{partner_response[:access_token]}" })

# https://www.tesla.com/_ak/ardesian.com

# ### Command:
# BE → Proxy → Fleet API → Vehicle

class Oauth::TeslaApi < Oauth::Base
  # Use `true` except when bypassing and hitting the Go server directly while local
  USE_LOCAL_RAILS_PROXY = true

  # Opt-in flag for hitting the real Tesla API from dev/test consoles. Default
  # `false` raises on any outbound call so a stray Sidekiq job or careless
  # console line can't fire a real command/refresh. The TeslaSetup wizard
  # flips this on for the duration of its operations; nothing else should.
  cattr_accessor :force_live_dev, default: false
  constants(
    api_url:         "https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/",
    oauth_url:       "https://auth.tesla.com/oauth2/v3/authorize",
    exchange_url:    "https://auth.tesla.com/oauth2/v3/token",
    client_id:       ENV.fetch("PORTFOLIO_TESLA_CLIENT_ID"),
    client_secret:   ENV.fetch("PORTFOLIO_TESLA_CLIENT_SECRET"),
    scopes:          "openid offline_access vehicle_device_data vehicle_cmds vehicle_charging_cmds vehicle_location",
    redirect_uri:    "https://ardesian.com/webhooks/auth",
    storage_key:     :tesla_api,
    auth_params:     {
      state: (DataStorage[:tesla_stable_state] ||= SecureRandom.hex),
      nonce: (DataStorage[:tesla_code_verifier] ||= rand(36**86).to_s(36)),
      # CODE_CHALLENGE = ::Base64.urlsafe_encode64(::Digest::SHA256.digest(CODE_VERIFIER), padding: false)
    },
    exchange_params: {
      audience: "https://fleet-api.prd.na.vn.cloud.tesla.com",
    },
  )
  # 403 Forbidden - Everything bad
  # 401 Unauthorized - Refresh Oauth Token
  # (t = Oauth::TeslaApi.new(User.me)).auth_url
  # * follow url
  # t.code = "NA_..."
  # 408 Request Timeout - Wake up
  # 406 Not Acceptable (RestClient::NotAcceptable)

  # Oauth::TeslaApi.me.request_telemetry
  # fleet_telemetry_config MUST go through the Vehicle Command HTTP Proxy
  # (the Go signing proxy at localhost:8752). Tesla returns
  #   "This endpoint must be called through the Vehicle Command HTTP Proxy"
  # otherwise. So we keep this on proxy_post, same as actual vehicle commands.
  def request_telemetry
    proxy_post("vehicles/fleet_telemetry_config", {
      vins:   [Tesla.vin],
      config: {
        alert_types: ["service"],
        fields:      TeslaService.fields(30.minutes),
        ca:          telemetry_ca,
        hostname:    "ardesian.com",
        port:        4443,
      },
    })
  end

  # CA bundle that Tesla will use to validate ardesian.com:4443's TLS cert.
  # Prod serves an LE cert via the fleet-telemetry server, so we hand Tesla
  # the LE chain. On dev (no real fleet-telemetry server), fall back to the
  # legacy self-signed cert so the registration call still parses.
  def telemetry_ca
    le_chain = "/etc/letsencrypt/live/ardesian.com/chain.pem"
    return File.read(le_chain) if File.exist?(le_chain)

    File.read("_scripts/tesla_keys/cert.pem")
  end

  def check_telemetry
    get("vehicles/#{Tesla.vin}/fleet_telemetry_config")
  end

  def fleet_status
    proxy_post("vehicles/fleet_status", vins: [Tesla.vin])
  end

  def proxy_post(path, params={}, headers={})
    must_be_live!
    if USE_LOCAL_RAILS_PROXY
      Api.request(
        method:  :post,
        url:     url(path, base: "#{DataStorage[:local_ip]}:3142/api/1/"),
        payload: params,
        headers: base_headers.merge(headers),
      )
    else
      Api.request(
        method:      :post,
        url:         url(path, base: "https://localhost:8752/api/1/"),
        payload:     params,
        headers:     base_headers.merge(headers),
        ssl_ca_file: "_scripts/tesla_keys/cert.pem",
      )
    end
  end

  def proxy_refresh
    refresh(exchange_url: "#{DataStorage[:local_ip]}:3142/tesla_refresh") if USE_LOCAL_RAILS_PROXY
  end

  # All Oauth::Base#get/#post/#put/#delete go through #request. Gate them at
  # this single entry point so any outbound traffic in non-prod requires
  # explicit opt-in via `Oauth::TeslaApi.force_live_dev = true`.
  def request(path, method, params={}, headers={}, opts={})
    must_be_live!
    super
  end

  private

  def must_be_live!
    if ::TeslaSwitch.disabled?
      ::TeslaSwitch.maybe_remind_muted!(:oauth_tesla_api)
      raise "Tesla calls are muted via TeslaSwitch (`#{::TeslaSwitch.reason || "no reason set"}`). " \
            "Re-enable with `TeslaSwitch.enable!` or via the Slack link."
    end
    return if ::Rails.env.production?
    return if self.class.force_live_dev

    raise "Tesla external request blocked in #{::Rails.env}. " \
          "Set `Oauth::TeslaApi.force_live_dev = true` to opt in, " \
          "or run via the TeslaSetup wizard which manages the flag for you."
  end

  public

  # Override Oauth::Base#refresh so the automatic 401-retry path inside
  # Oauth::Base#request also goes through the home relay in prod. Without
  # this, auto-refresh hits auth.tesla.com directly and fails on DO IPs.
  def refresh(params={})
    if ::Rails.env.production? && USE_LOCAL_RAILS_PROXY && params[:exchange_url].blank?
      params = params.merge(exchange_url: "#{DataStorage[:local_ip]}:3142/tesla_refresh")
    end
    super
  end

  # Override Oauth::Base#code= so prod can do the auth-code exchange via the
  # home Ruby relay instead of directly hitting auth.tesla.com (whose IP
  # filter blocks DigitalOcean addresses). Local dev still goes direct.
  def code=(code)
    args = { code: code, grant_type: :authorization_code }.merge(self.class.preset_constants[:exchange_params])
    args[:exchange_url] = "#{DataStorage[:local_ip]}:3142/tesla_refresh" if ::Rails.env.production?
    auth(args).compact_blank
    self
  end
end
