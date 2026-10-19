module Buddy
  # What a companion says when nobody wrote the line but us.
  #
  # Most of what a pet says comes from the model, in its own voice. A few
  # things don't: a routine tapped on the Quick grid or the kiosk runs
  # deterministically with no model turn behind it (see Buddy::Routines#run!),
  # so the announcement over it is ours to write — and written once, flat, it
  # comes out of every pet identically. "Running **Yoga Lamp**" is Glimmer, a
  # firefly who talks about breath and light, sounding like a job scheduler.
  #
  # So: one set of lines per theme, in that pet's own register, with the thing
  # being done interpolated in. A line carries its FACE as well as its words,
  # because those two have to agree — the persona's own rule — and pairing them
  # here is the only way they can't drift apart.
  #
  # Faces are checked against what the theme can actually render (Buddy::Faces
  # reads the image files), so a face that gets removed from the art degrades
  # to "no expression change" rather than a blank pet.
  module VoiceLines
    module_function

    # `%<name>s` is the routine being run. `routine_empty` deliberately has no
    # name in it: it lands directly under the line that just said it.
    #
    # Ten of each, because the point is that it doesn't sound canned. Four gets
    # recognised inside a week on a wall tablet somebody walks past all day, and
    # a line you can predict is one nobody reads — at which point it may as well
    # have stayed "Running X".
    #
    # `chore_done` is the small encouraging line over a chore just ticked off on
    # a board - `%<name>s` is the chore's short name. Ten, and for the same
    # reason as above with more force behind it: a board is a wall tablet that
    # gets pressed several times a day, every day, so a set of four is
    # recognised by the end of the week and then it is wallpaper. The lines are
    # about the PERSON, not the chore - what is being said is well done, and
    # the circle going grey is what reports the chore.
    #
    # `wake_yawn` carries no name: it lands when a board that has been dark a
    # long time comes back, and there is nothing to interpolate.
    #
    # `kind` is open. Anything the system says in a pet's own voice belongs in
    # the pets' voice_lines.rb files (app/service/buddy/companions/<pet>/): add a
    # `lines` block, write ten, and Buddy::VoiceLines#pick does the rest.

    # What a pet's voice_lines.rb is evaluated in. The file is a list of
    # `lines :kind do … end` blocks, each a list of `say "…", mood: :face`.
    class Builder
      def self.load(path)
        builder = new
        builder.instance_eval(File.read(path), path.to_s) if File.exist?(path)
        builder.table.freeze
      end

      attr_reader :table

      def initialize
        @table = {}
      end

      def lines(kind, &)
        @current = @table[kind.to_sym] = []
        instance_eval(&)
      ensure
        @current = nil
      end

      def say(text, mood:)
        raise ArgumentError, "`say` belongs inside a `lines` block" if @current.nil?

        @current << { say: text.freeze, mood: mood&.to_sym }.freeze
      end
    end

    # { theme => { kind => [line, …] } } for every pet that has written lines.
    def table
      Buddy::Companion.all.transform_values(&:voice_lines).reject { |_theme, kinds| kinds.empty? }
    end

    # A line and the face that goes with it: `{ text:, mood: }`. `mood` is nil
    # when the theme can't render the one the line asked for, which reads as
    # "say this, leave the face alone".
    #
    # `avoid` is the face the pet is already wearing. Two taps in a row landing
    # the same expression is a pet that didn't react to the second one, so a
    # line wearing a different face is preferred — but only preferred: the
    # words matter more than the novelty, and a set of one still speaks.
    # `unlike` is something already said — the message before this one. Any line
    # that opens it is dropped, which is how "never the same hello twice
    # running" becomes true rather than instructed.
    def pick(theme, kind, avoid: nil, unlike: nil, **vars)
      set = lines_for(theme, kind)
      return { text: "", mood: nil } if set.empty?

      fresh = set.reject { |line| line[:mood].to_s == avoid.to_s || said_already?(line, unlike) }
      line  = (fresh.presence || set).sample

      { text: render(line[:say], vars), mood: mood_for(theme, line[:mood]) }
    end

    def said_already?(line, text)
      return false if text.blank?

      text.to_s.lstrip.start_with?(line[:say])
    end

    # A pet with no lines of a kind borrows the default pet's. An unknown theme
    # reads as the default rather than raising (Buddy::Companion.find) — the
    # value arrives from a database column.
    def lines_for(theme, kind)
      own = Buddy::Companion.find(theme).voice_lines[kind.to_sym]
      Array(own.presence || Buddy::Companion.find(Buddy::Companion::DEFAULT).voice_lines[kind.to_sym])
    end

    # A face is only ever offered if the theme can render it AND it's a mood
    # rather than a system/transitional face — `selectable?` is the same gate a
    # `[[mood:]]` marker goes through.
    def mood_for(theme, mood)
      return nil if mood.blank?

      Buddy::Faces.selectable?(theme, mood) ? mood.to_sym : nil
    end

    # A missing key would raise mid-announcement, and the announcement is the
    # part that matters — a routine that ran deserves to say so even if the
    # line was written with a placeholder nobody fills.
    def render(say, vars)
      format(say, **vars)
    rescue KeyError, ArgumentError => e
      Rails.logger.warn("[Buddy::VoiceLines] #{say.inspect}: #{e.class}: #{e.message}")
      say
    end
  end
end
