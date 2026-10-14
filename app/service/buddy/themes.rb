module Buddy
  # The chrome table, now a thin facade over the companion classes.
  #
  # Each pet's name, colour, icons, manifests and tone used to be spelled out in
  # a big literal here. They live on the companion now (Buddy::Companions::*),
  # and this derives the same `{theme => chrome}` shape from them so every
  # caller — the favicon partial, the header, the PWA manifests, SleepGuard —
  # keeps working unchanged. Adding a companion is a class under
  # Buddy::Companions and its asset folder; nothing here.
  #
  # - `tone` is whose voice profile the companion speaks with
  #   (app/service/buddy/tone_profiles); the persona file is the pet's own name
  #   in app/service/buddy/personalities. Both are pointers the companion holds.
  # - The chrome keys drive the PWA install: the home-screen name, which icon,
  #   which manifest, and the colour the browser paints around it.
  module Themes
    module_function

    DEFAULT = Buddy::Companion::DEFAULT

    # { theme => chrome-hash }, in display order. Live off the companions, so a
    # tweak to one shows up without anything here to update.
    def all
      Buddy::Companion.all.transform_values(&:chrome)
    end

    # Anything unrecognised reads as the default rather than raising — a theme
    # string arrives from a database column and a slash command, and a typo
    # should land on Byte, not an error page.
    def for(theme)
      Buddy::Companion.find(theme).chrome
    end

    def keys
      Buddy::Companion.keys
    end

    def name_for(theme)
      self.for(theme)[:name]
    end

    def tone_for(theme)
      self.for(theme)[:tone]
    end

    # Every pet's display name, for a "byte|moss|suki" usage string.
    def names
      all.values.pluck(:name)
    end
  end
end
