# Be sure to restart your server when you modify this file.

Rails.application.config.session_store(
  :cookie_store,
  key: "_Portfolio_session",
  domain: :all,
  tld_length: 2,
  same_site: :lax,
  secure: true
)
