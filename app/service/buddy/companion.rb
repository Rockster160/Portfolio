module Buddy
  # One companion = one service class. Everything that used to be smeared across
  # Buddy::Themes (the chrome table), Buddy::Faces::INDEX (per-pet mood numbers)
  # and Buddy::Faces::HINTS (face descriptions) now lives in a single subclass
  # per pet under Buddy::Companions — its name, description, a one-line
  # personality summary, its persona and voice lines, a pointer to its tone file,
  # and the list of expressions it wears. Buddy::Themes and Buddy::Faces are thin facades over
  # these, so nothing else had to change.
  #
  # A companion sets its emotions individually, each with its own summary (what
  # the drawing is) and axes (the four mood values + reach that decide when the
  # picker reaches for it). They are NOT shared between pets: Byte's `eager` and
  # Suki's `eager` are free to carry different weights, because their art and
  # their characters differ.
  #
  # Each pet is a FOLDER, app/service/buddy/companions/<pet>/, holding everything
  # that is that pet's alone: this class (<pet>.rb), its persona (persona.md,
  # loaded by Buddy::Personality) and its voice lines (voice_lines.rb, see
  # Buddy::VoiceLines). Adding a companion is that folder plus its expression
  # images on disk — no edits anywhere else. The tone is a POINTER to a file in
  # app/service/buddy/tone_profiles, which describes the person, not the pet.
  class Companion
    DEFAULT = :byte

    # Display order, Byte (the default) first; a companion not listed sorts
    # after the listed ones, alphabetically. Drives the drawer, the theme
    # switcher, and the "byte|moss|…" usage strings.
    ORDER = %i[byte moss suki glimmer kumoko mocha ghosty flux tiko gizmo bloom cobalt].freeze

    COMPANION_DIR = Rails.root.join("app/service/buddy/companions")

    class << self
      # ---- DSL, declared in each companion subclass ------------------------

      # Who the pet is and how the app is dressed for it. `tone` is the stem of
      # its file under tone_profiles/. `chrome` overrides the conventional asset paths for the odd one out
      # (Byte, whose icon filenames carry no `byte-` prefix).
      def identity(key:, name:, description:, color:, tone:, chrome: {})
        @theme            = key.to_sym
        @display_name     = name
        @description      = description
        @color            = color
        @tone             = tone.to_sym
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

      # The face the pet flips to while an alarm rings, alternating with its
      # resting face. Left unset, it is the drawn face nearest the alarm's
      # point on the mood axes (Buddy::Faces::STATE_POINTS).
      def alarm_face(name=nil)
        return @alarm_face || Buddy::Faces.resolve(theme, :alarm) if name.nil?

        @alarm_face = name.to_sym
      end

      # ---- readers ---------------------------------------------------------

      attr_reader :theme, :display_name, :description, :color, :tone

      # This pet's own folder.
      def dir
        COMPANION_DIR.join(theme.to_s)
      end

      def persona_path
        dir.join("persona.md")
      end

      # { kind => [{ say:, mood: }, …] } from the pet's voice_lines.rb. Re-read
      # every call in development, where the file is edited under a running
      # server and the autoloader doesn't watch it.
      def voice_lines
        return Buddy::VoiceLines::Builder.load(dir.join("voice_lines.rb")) if Rails.env.development?

        @voice_lines ||= Buddy::VoiceLines::Builder.load(dir.join("voice_lines.rb"))
      end

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
        COMPANION_DIR.glob("*/*.rb")
          .select { |path| path.basename(".rb").to_s == path.dirname.basename.to_s }
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
