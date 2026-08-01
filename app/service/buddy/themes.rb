module Buddy
  # Everything that differs between companions, in one table.
  #
  # A pet used to be spelled out wherever it mattered: a `case` in the favicon
  # partial, another in the header, a ternary in SleepGuard that knew about Moss
  # and nothing else, and several branches keyed off a USER ID rather than the
  # theme. That meant adding a pet touched half a dozen files, and a thread whose
  # theme differed from its owner's default (Rocco opening a Suki thread) showed
  # the wrong name, icon, and voice.
  #
  # So: one entry per pet, keyed by theme, and nothing anywhere keys off who the
  # user is. Adding a companion is this table plus its asset folder.
  #
  # - `tone` is whose voice profile that companion speaks with
  #   (app/service/buddy/tone_profiles). The persona file is the theme's own
  #   name in app/service/buddy/personalities.
  # - The chrome keys drive the PWA install: what it's called on a home screen,
  #   which icon, which manifest, what colour the browser paints around it.
  #   `kiosk_manifest` is the same pet installed as the wall-tablet view — a
  #   second manifest rather than a flag, because `start_url` is what makes the
  #   home-screen icon open the kiosk instead of the chat.
  module Themes
    module_function

    DEFAULT = :byte

    ALL = {
      byte: {
        name:           "Byte",
        tone:           :rocco,
        color:          "#0E1930",
        avatar:         "byte_favicon/byte.png",
        touch_icon:     "byte_favicon/apple-touch-icon.png",
        favicon:        "byte_favicon/favicon-96x96.png",
        manifest:       "/byte.webmanifest",
        kiosk_manifest: "/byte_kiosk.webmanifest",
      },
      moss: {
        name:           "Moss",
        tone:           :chelsea,
        color:          "#14231A",
        avatar:         "moss_favicon/moss.png",
        touch_icon:     "moss_favicon/moss-apple-touch-icon.png",
        favicon:        "moss_favicon/moss-favicon-96x96.png",
        manifest:       "/moss.webmanifest",
        kiosk_manifest: "/moss_kiosk.webmanifest",
      },
      suki: {
        name:           "Suki",
        tone:           :eve,
        color:          "#150A22",
        avatar:         "suki_favicon/suki.png",
        touch_icon:     "suki_favicon/suki-apple-touch-icon.png",
        favicon:        "suki_favicon/suki-favicon-96x96.png",
        manifest:       "/suki.webmanifest",
        kiosk_manifest: "/suki_kiosk.webmanifest",
      },
      glimmer: {
        name:           "Glimmer",
        tone:           :chelsea,
        color:          "#2A1E0A",
        avatar:         "glimmer_favicon/glimmer.png",
        touch_icon:     "glimmer_favicon/glimmer-apple-touch-icon.png",
        favicon:        "glimmer_favicon/glimmer-favicon-96x96.png",
        manifest:       "/glimmer.webmanifest",
        kiosk_manifest: "/glimmer_kiosk.webmanifest",
      },
    }.freeze

    # Anything unrecognised reads as the default rather than raising — a theme
    # string arrives from a database column and a slash command, and a typo
    # should land you on Byte, not on an error page.
    def for(theme)
      ALL.fetch(theme.to_s.to_sym, ALL[DEFAULT])
    end

    def keys
      ALL.keys
    end

    def name_for(theme)
      self.for(theme)[:name]
    end

    def tone_for(theme)
      self.for(theme)[:tone]
    end

    # Every pet's display name, for a "byte|moss|suki" usage string.
    def names
      ALL.values.pluck(:name)
    end
  end
end
