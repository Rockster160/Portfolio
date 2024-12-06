class Oauth::SpotifyApi < Oauth::Base
  include ::ActionView::Helpers::NumberHelper

  constants(
    oauth_url: "https://accounts.spotify.com/authorize",
    exchange_url: "https://accounts.spotify.com/api/token",
    api_url: "https://api.spotify.com/v1",
    scopes: %w[user-read-playback-state user-modify-playback-state user-read-currently-playing],
  )
end
