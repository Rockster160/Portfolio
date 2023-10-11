class Oauth::TeslaAPI < Oauth::Base
  constants(
    OAUTH_URL: "https://auth.tesla.com/oauth2/v3/authorize",
    EXCHANGE_URL: "https://auth.tesla.com/oauth2/v3/token",
    CLIENT_ID: ENV.fetch("PORTFOLIO_TESLA_CLIENT_ID"),
    CLIENT_SECRET: ENV.fetch("PORTFOLIO_TESLA_CLIENT_SECRET"),
    SCOPES: "openid vehicle_device_data vehicle_cmds vehicle_charging_cmds",
    REDIRECT_URI: "https://ardesian.com/webhooks/auth",
    STORAGE_KEY: :tesla_api,
    AUTH_PARAMS: {
      state: TeslaControl::STABLE_STATE,
      nonce: TeslaControl::CODE_VERIFIER,
    },
    EXCHANGE_PARAMS: {
      audience: "https://fleet-api.prd.na.vn.cloud.tesla.com",
    },
  )
end
