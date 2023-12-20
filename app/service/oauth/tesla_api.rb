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
      state: TeslaControl::STABLE_STATE,
      nonce: TeslaControl::CODE_VERIFIER,
    },
    exchange_params: {
      audience: "https://fleet-api.prd.na.vn.cloud.tesla.com",
    },
  )
end
