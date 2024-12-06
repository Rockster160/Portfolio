class Oauth::SpotifyApi < Oauth::Base
  include ::ActionView::Helpers::NumberHelper

  constants(
    oauth_url: "https://accounts.spotify.com/authorize",
    exchange_url: "https://accounts.spotify.com/api/token",
    api_url: "https://api.spotify.com/v1",
    scopes: [
      "user-read-email",
      "user-read-private",
      "user-read-playback-state",
      "user-modify-playback-state",
      "user-read-currently-playing",
    ],
  )

  def me
    get("/me")
    # {
    #   display_name: "ArdesianSpotify",
    #   external_urls: { spotify: "https://open.spotify.com/user/dbn8t2estuwbg4r20wv4fo2fb" },
    #   followers: { href: nil, total: 0 },
    #   href: "https://api.spotify.com/v1/users/dbn8t2estuwbg4r20wv4fo2fb",
    #   id: "dbn8t2estuwbg4r20wv4fo2fb",
    #   images: [],
    #   type: "user",
    #   uri: "spotify:user:dbn8t2estuwbg4r20wv4fo2fb"
    # }
  end

  def devices
    get("/me/player/devices")
    # {
    #   "devices": [
    #     {
    #       "id": "string",
    #       "is_active": false,
    #       "is_private_session": false,
    #       "is_restricted": false,
    #       "name": "Kitchen speaker",
    #       "type": "computer",
    #       "volume_percent": 59,
    #       "supports_volume": false
    #     }
    #   ]
    # }
  end

  def device=(new_device)
    put("/me/player", { device_ids: Array.wrap(new_device), play: true })
  end
end
