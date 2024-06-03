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
  constants(
    api_url: "https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/",
    oauth_url: "https://auth.tesla.com/oauth2/v3/authorize",
    exchange_url: "https://auth.tesla.com/oauth2/v3/token",
    client_id: ENV.fetch("PORTFOLIO_TESLA_CLIENT_ID"),
    client_secret: ENV.fetch("PORTFOLIO_TESLA_CLIENT_SECRET"),
    scopes: "openid offline_access vehicle_device_data vehicle_cmds vehicle_charging_cmds",
    redirect_uri: "https://ardesian.com/webhooks/auth",
    storage_key: :tesla_api,
    auth_params: {
      state: (DataStorage[:tesla_stable_state] ||= SecureRandom.hex),
      nonce: (DataStorage[:tesla_code_verifier] ||= rand(36**86).to_s(36)),
      # CODE_CHALLENGE = ::Base64.urlsafe_encode64(::Digest::SHA256.digest(CODE_VERIFIER), padding: false)
    },
    exchange_params: {
      audience: "https://fleet-api.prd.na.vn.cloud.tesla.com",
    }
  )
  # 403 Forbidden - Everything bad
  # 401 Unauthorized - Refresh Oauth Token
  # 408 Request Timeout - Wake up
  # 406 Not Acceptable (RestClient::NotAcceptable)

  # Use `true` except when bypassing and hitting the Go server directly while local
  USE_LOCAL_RAILS_PROXY = true
  def proxy_post(path, params={}, headers={})
    if USE_LOCAL_RAILS_PROXY
      Api.request(
        method: :post,
        url: url(path, base: "#{DataStorage[:local_ip]}:3142/api/1/"),
        payload: params,
        headers: base_headers.merge(headers),
      )
    else
      Api.request(
        method: :post,
        url: url(path, base: "https://localhost:8752/api/1/"),
        payload: params,
        headers: base_headers.merge(headers),
        ssl_ca_file: "_scripts/tesla_keys/cert.pem",
      )
    end
  end

  def proxy_refresh
    if USE_LOCAL_RAILS_PROXY
      refresh(exchange_url: "#{DataStorage[:local_ip]}:3142/tesla_refresh")
      # Api.request(
      #   method: :post,
      #   url: ,
      #   payload: params,
      #   headers: base_headers.merge(headers),
      # )
    else
      # Api.request(
      #   method: :post,
      #   url: url(path, base: "https://localhost:8752/api/1/"),
      #   payload: params,
      #   headers: base_headers.merge(headers),
      #   ssl_ca_file: "_scripts/tesla_keys/cert.pem",
      # )
    end
  end
end
