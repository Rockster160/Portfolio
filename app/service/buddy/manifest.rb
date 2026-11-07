module Buddy
  # The two install manifests every pet has, built from its companion class:
  # the chat (opens the app) and the kiosk (opens the wall view at /kiosk).
  # They differ only in `id`, `start_url`, name and description — the `id` is
  # what lets both live on one home screen as separate icons, and it must never
  # change, or an icon already installed stops being recognised as this app.
  module Manifest
    module_function

    def for(theme, kiosk: false)
      pet = Buddy::Companion.find(theme)
      kiosk ? kiosk_manifest(pet) : chat_manifest(pet)
    end

    def chat_manifest(pet)
      {
        short_name:  pet.display_name,
        name:        pet.display_name,
        icons:       icons(pet.theme),
        id:          pet.theme.to_s,
        start_url:   "/?source=pwa",
        description: pet.install_description,
        **shared(pet),
      }
    end

    def kiosk_manifest(pet)
      name = "#{pet.display_name} Kiosk"
      {
        short_name:  name,
        name:        name,
        icons:       icons(pet.theme),
        id:          "#{pet.theme}-kiosk",
        start_url:   "/kiosk",
        orientation: :any,
        description: "#{pet.display_name} on the wall: the character, and the routines you tap.",
        **shared(pet),
      }
    end

    def shared(pet)
      {
        background_color: pet.install_background,
        display:          :standalone,
        scope:            "/",
        theme_color:      pet.color,
      }
    end

    def icons(theme)
      [192, 512].map { |size|
        {
          src:     "/#{theme}_favicon/web-app-manifest-#{size}x#{size}.png",
          sizes:   "#{size}x#{size}",
          type:    "image/png",
          purpose: :maskable,
        }
      }
    end
  end
end
