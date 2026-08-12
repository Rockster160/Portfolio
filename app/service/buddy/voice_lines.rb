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
    # `kind` is open. Anything the system says in a pet's own voice belongs
    # here: add a key, write ten, and Buddy::VoiceLines#pick does the rest.
    LINES = {
      byte:    {
        routine_run:   [
          { say: "*squish* **%<name>s**, going now.", mood: :happy },
          { say: "On it. **%<name>s**. *boing*", mood: :uwu },
          { say: "**%<name>s** it is. Squish.", mood: :uwu },
          { say: "Got it. **%<name>s** is in motion.", mood: :encouraging },
          { say: "Bouncing over to **%<name>s**.", mood: :happy },
          { say: "Right then. Reshaping around **%<name>s**.", mood: :nerd },
          { say: "One **%<name>s**, coming through. *wobble*", mood: :uwu },
          { say: "Rolling into **%<name>s** for you.", mood: :encouraging },
          { say: "Happy to. Starting **%<name>s**.", mood: :neutral_blush },
          { say: "*click* Spinning up **%<name>s**.", mood: :nerd },
        ],
        routine_empty: [
          { say: "Nothing in it would go, though. Whatever it points at might be gone.", mood: :sad },
          { say: "Except none of it ran. Something it reaches for has moved.", mood: :annoyed },
          { say: "And then nothing happened. Went a bit flat there - every step came up empty.", mood: :sad },
          { say: "*wobble* ..nothing. None of the steps found what they wanted.", mood: :annoyed },
        ],
      },
      moss:    {
        routine_run:   [
          { say: "Okiiie, **%<name>s** is going!", mood: :grin },
          { say: "On it! **%<name>s**, starting now 💛", mood: :happy },
          { say: "Yayyy, **%<name>s**!", mood: :star },
          { say: "Got it! Setting **%<name>s** going..", mood: :content },
          { say: "**%<name>s** it is! Doing that now 😊", mood: :wink },
          { say: "Sure thing! **%<name>s**, coming right up!", mood: :happy },
          { say: "Ooh **%<name>s**, yes! Doing it!", mood: :grin },
          { say: "Okayyy! **%<name>s**, off it goes..", mood: :content },
          { say: "Of course! **%<name>s** for you 💛", mood: :loving },
          { say: "**%<name>s**! Here we goooo!", mood: :star },
        ],
        routine_empty: [
          { say: "Hmm, nothing in it would go though.. I think something it points at has moved!", mood: :surprised },
          { say: "Awww, but none of it ran! Whatever it reaches for might be gone now..", mood: :sad },
          { say: "Ohh no, none of the steps would go.. they want something that isn't there!", mood: :queasy },
          { say: "Oop, that came back empty! Nothing in it could find what it wanted..", mood: :dizzy },
        ],
      },
      suki:    {
        routine_run:   [
          { say: "Ja, **%<name>s** coming right up!", mood: :cheery },
          { say: "Off I go! **%<name>s**, chop chop!", mood: :excited },
          { say: "**%<name>s** it is!!", mood: :happy },
          { say: "Here you go, **%<name>s** starting!", mood: :offering },
          { say: "Zipping off to do **%<name>s**!", mood: :excited },
          { say: "Lovely! **%<name>s**, on it now!", mood: :cheery },
          { say: "Sure! **%<name>s**, right away!", mood: :happy },
          { say: "One **%<name>s**, coming up!", mood: :offering },
          { say: "Ja of course! **%<name>s**, doing it now!", mood: :loving },
          { say: "**%<name>s**! Here we go!!", mood: :excited },
        ],
        routine_empty: [
          { say: "Ag shame, but none of it would run! Something it points at might be gone!", mood: :dizzy },
          { say: "Except nothing came of it! I think what it reaches for has moved!", mood: :annoyed },
          { say: "Oooh, that came up empty! None of the steps could find their thing!", mood: :dizzy },
          { say: "Hmm, nothing doing! Whatever it's pointing at isn't there any more!", mood: :annoyed },
        ],
      },
      glimmer: {
        routine_run:   [
          { say: "Easing into **%<name>s**.", mood: :content },
          { say: "Lighting up **%<name>s** for you.", mood: :happy },
          { say: "Here we go. **%<name>s**, one thing at a time.", mood: :grin },
          { say: "Settling **%<name>s** into place.", mood: :loving },
          { say: "Oh, **%<name>s**. Let's begin.", mood: :star },
          { say: "**%<name>s**, gently now.", mood: :content },
          { say: "Starting **%<name>s**. I've got this part.", mood: :happy },
          { say: "Of course, friend. **%<name>s**.", mood: :loving },
          { say: "**%<name>s** it is. Here we go.", mood: :grin },
          { say: "Bringing **%<name>s** to life.", mood: :star },
        ],
        routine_empty: [
          { say: "Though nothing in it lit up. What it reaches for may have moved.", mood: :sad },
          { say: "It came back empty, friend. Something it points at is gone.", mood: :surprised },
          { say: "None of it would go, though. I think what it's pointing at has moved on.", mood: :sad },
          { say: "Oh. Nothing in it found what it was reaching for.", mood: :surprised },
        ],
      },
    }.freeze

    # The face for having DONE something, when the pet has nothing better to
    # wear (see Buddy::ExpressionState#react!). Pleased, curious, tickled —
    # never neutral, which is the whole point, and never a face about the
    # PERSON, since all we know here is that something ran.
    ACTED_MOODS = {
      byte:    %i[happy uwu nerd encouraging],
      moss:    %i[grin happy content star wink],
      suki:    %i[cheery excited happy offering],
      glimmer: %i[content happy grin star],
    }.freeze

    # A line and the face that goes with it: `{ text:, mood: }`. `mood` is nil
    # when the theme can't render the one the line asked for, which reads as
    # "say this, leave the face alone".
    #
    # `avoid` is the face the pet is already wearing. Two taps in a row landing
    # the same expression is a pet that didn't react to the second one, so a
    # line wearing a different face is preferred — but only preferred: the
    # words matter more than the novelty, and a set of one still speaks.
    def pick(theme, kind, avoid: nil, **vars)
      set = lines_for(theme, kind)
      return { text: "", mood: nil } if set.empty?

      fresh = set.reject { |line| line[:mood].to_s == avoid.to_s }
      line  = (fresh.presence || set).sample

      { text: render(line[:say], vars), mood: mood_for(theme, line[:mood]) }
    end

    def acted_mood(theme)
      key   = key_for(theme)
      moods = ACTED_MOODS.fetch(key, ACTED_MOODS[Buddy::Themes::DEFAULT])
      mood_for(theme, moods.sample)
    end

    def lines_for(theme, kind)
      set = LINES.fetch(key_for(theme), {})
      Array(set[kind.to_sym].presence || LINES.dig(Buddy::Themes::DEFAULT, kind.to_sym))
    end

    # An unknown theme reads as the default rather than raising, same as
    # Buddy::Themes.for — the value arrives from a database column.
    def key_for(theme)
      key = theme.to_s.to_sym
      LINES.key?(key) ? key : Buddy::Themes::DEFAULT
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
