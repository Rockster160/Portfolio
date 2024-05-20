# o = ::Oauth::TeslaApi.new(User.me)
# partner_response = o.post("https://auth.tesla.com/oauth2/v3/token", {
#   grant_type: :client_credentials,
#   client_id: o.client_id,
#   client_secret: o.client_secret,
#   scope: o.scopes,
#   audience: "https://fleet-api.prd.na.vn.cloud.tesla.com"
# })

# o.auth_url
# post(:partner_accounts, { domain: "ardesian.com" }, { Authorization: "Bearer #{partner_response[:access_token]}" })

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
    },
  )

  # o = ::Oauth::TeslaApi.new(User.me)
  # o.auth_url <click open and follow path, copy `code` param -- should be automatic in prod?>
  # o.code = "NA..."
  #

  # t = TeslaControl.me
  # bearer = post("https://auth.tesla.com/oauth2/v3/token", { grant_type: :client_credentials, client_id: @client_id, client_secret: @client_secret, scope: @scopes, audience: "https://fleet-api.prd.na.vn.cloud.tesla.com" })
  # partner = post(:partner_accounts, { domain: "ardesian.com" }, { Authorization: "Bearer #{bearer[:access_token]}" })
end
