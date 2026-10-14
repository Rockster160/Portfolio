module Buddy
  # One companion = one service class. Everything that used to be smeared across
  # Buddy::Themes (the chrome table), Buddy::Faces::INDEX (per-pet mood numbers)
  # and Buddy::Faces::HINTS (face descriptions) now lives in a single subclass
  # per pet under Buddy::Companions — its name, description, a one-line
  # personality summary, pointers to its persona and tone files, and the list of
  # expressions it wears. Buddy::Themes and Buddy::Faces are thin facades over
  # these, so nothing else had to change.
  #
  # A companion sets its emotions individually, each with its own summary (what
  # the drawing is) and axes (the four mood values + reach that decide when the
  # picker reaches for it). They are NOT shared between pets: Byte's `eager` and
  # Suki's `eager` are free to carry different weights, because their art and
  # their characters differ. Adding a companion is: this class, its expression
  # images on disk, and its persona + tone files — no edits anywhere else.
  #
  # The persona and tone are POINTERS to files (app/service/buddy/personalities
  # and .../tone_profiles), loaded by Buddy::Personality; everything else is here
  # in the class.
  class Companion
    DEFAULT = :byte

    # Display order, Byte (the default) first; a companion not listed sorts
    # after the listed ones, alphabetically. Drives the drawer, the theme
    # switcher, and the "byte|moss|…" usage strings.
    ORDER = %i[byte moss suki glimmer kumoko mocha ghosty flux tiko gizmo sprig cobalt].freeze

    COMPANION_DIR = Rails.root.join("app/service/buddy/companions")

    class << self
      # ---- DSL, declared in each companion subclass ------------------------

      # Who the pet is and how the app is dressed for it. `tone` and `persona`
      # are the stems of the files under tone_profiles/ and personalities/.
      # `persona` defaults to the theme key (every persona file is theme-named).
      # `chrome` overrides the conventional asset paths for the odd one out
      # (Byte, whose icon filenames carry no `byte-` prefix).
      def identity(key:, name:, description:, color:, tone:, persona: nil, chrome: {})
        @theme            = key.to_sym
        @display_name     = name
        @description      = description
        @color            = color
        @tone             = tone.to_sym
        @persona          = (persona || key).to_sym
        @chrome_overrides = chrome
      end

      def summary(text=nil)
        return @summary if text.nil?

        @summary = text
      end

      # This pet's emotions, each `name: { summary:, axes: { warmth:, play:,
      # weight:, strain:, reach: } }`. Set in full, per pet — nothing is shared
      # with another companion, so one pet's `eager` can weigh differently from
      # another's.
      def emotions(**defs)
        @emotions ||= {}
        defs.each { |name, spec|
          @emotions[name.to_sym] = { summary: spec[:summary], axes: spec[:axes] }
        }
      end

      # ---- readers ---------------------------------------------------------

      attr_reader :theme, :display_name, :description, :color, :tone, :persona

      def emotion_table
        @emotions || {}
      end

      # { face => { warmth, play, weight, strain, reach } } — the mood values the
      # picker works on.
      def faces
        emotion_table.transform_values { |spec| spec[:axes] }
      end

      # { face => sentence } — what each drawing is, for prompts and the lab.
      def summaries
        emotion_table.transform_values { |spec| spec[:summary] }
      end

      # The chrome table entry the app dresses itself from.
      def chrome
        {
          name:           display_name,
          tone:           tone,
          color:          color,
          avatar:         "#{theme}_favicon/#{theme}.png",
          touch_icon:     "#{theme}_favicon/#{theme}-apple-touch-icon.png",
          favicon:        "#{theme}_favicon/#{theme}-favicon-96x96.png",
          manifest:       "/#{theme}.webmanifest",
          kiosk_manifest: "/#{theme}_kiosk.webmanifest",
        }.merge(@chrome_overrides || {})
      end

      # ---- registry --------------------------------------------------------

      # { theme => companion-class }, in display order. Loads every companion
      # file (so lazy autoloading can't hide one) and re-reads the live classes
      # each call, so editing a companion in development takes effect without a
      # restart.
      def all
        COMPANION_DIR.glob("*.rb")
          .map { |path| "Buddy::Companions::#{path.basename(".rb").to_s.camelize}".constantize }
          .sort_by { |pet| [ORDER.index(pet.theme) || ORDER.size, pet.theme.to_s] }
          .index_by(&:theme)
      end

      delegate :keys, to: :all

      # Never raises — an unknown theme (a typo, a stale DB column) resolves to
      # the default, the way Buddy::Themes.for always has.
      def find(theme)
        all.fetch(theme.to_s.to_sym, all[DEFAULT])
      end
    end
  end
end
