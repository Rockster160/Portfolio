module Buddy
  # The CONDITION half of a watch - "when I get to Costco", "next time I finish
  # Brush Teeth", "when the washer stops" - resolved from what the person said
  # into the scope + match a BuddyWatch fires on.
  #
  # Lifted out of `remind_when` when `alarm` became a second tool hanging off
  # the same conditions. Two copies of place resolution, calendar ownership and
  # listener validation would drift, and the copy that drifted would be the one
  # that silently stops firing - which is the single failure mode a watch must
  # not have, because it looks identical to a condition that hasn't happened yet.
  module WatchCondition
    # `owner` is who the watch has to belong to. Most scopes fire for the user
    # themselves; `agenda_item` fires for the CALENDAR's owner (AgendaItem#user
    # delegates to its agenda), so an agenda watch filed under anyone else never
    # fires at all.
    #
    # `place_known` is false when a place was named but couldn't be pinned to
    # coordinates. The watch is still describable ("when you get to Costco") but
    # not settable, so the tool reports it and asks where the place is rather
    # than storing a name-only match that matches nothing.
    Resolved = Struct.new(
      :scope, :match, :listener, :human, :owner, :place_known, :place_name,
      keyword_init: true
    )

    TRIGGERS = %i[arrive depart chore event agenda whisper deploy custom].freeze

    # Which triggers reach into a feature. Watching for an arrival or a deploy
    # is everyone's; a chore watch would tell someone without chores when the
    # rest of the household finished theirs, which is the visibility the feature
    # block exists to prevent.
    GATED = { chore: :chores, event: :events, agenda: :agenda, whisper: :events }.freeze

    module_function

    # The same condition read as an ENDING rather than a trigger.
    #
    # `human` is minted for the trigger sense — "when the print finishes", which
    # is right for "tell me when the print finishes" and wrong the moment it's
    # what stops something: "every 30 min, when the print finishes" reads as a
    # second thing that happens rather than the point it stops. One word, and
    # it's the difference between a rule and a list of two events.
    def until_phrase(human)
      text = human.to_s.strip
      return nil if text.blank?

      "until #{text.sub(/\A(?:when(?:ever)?|once|after)\s+/i, "")}"
    end

    # Raises with a sentence the model can act on when the condition can't be
    # resolved - every raise here reaches the person as Buddy explaining what it
    # needs, so they read as questions rather than error text.
    def resolve(payload, ctx)
      trigger = payload[:trigger].to_s
      target  = payload[:target].to_s.strip

      case trigger
      when "arrive"  then place(ctx, target, action: "arrived", phrase: "when you get to")
      when "depart"  then place(ctx, target, action: "departed", phrase: "when you leave")
      when "chore"   then chore(ctx, target)
      when "event"   then event(ctx, target)
      when "agenda"  then agenda(ctx, target)
      when "whisper" then whisper(ctx, target)
      when "deploy"  then deploy(ctx)
      when "custom"  then custom(ctx, payload)
      else raise "unknown trigger #{trigger.inspect}"
      end
    end

    def place(ctx, target, action:, phrase:)
      resolved = ctx.resolve_place_location(target)
      raise "#{action == "arrived" ? "arrive" : "depart"} needs a place (target)" if resolved["name"].blank?

      Resolved.new(
        scope:       "travel",
        match:       { "action" => action, "place" => resolved.except("known") },
        human:       "#{phrase} #{resolved["name"]}",
        owner:       ctx.user,
        place_known: resolved["known"],
        place_name:  resolved["name"],
      )
    end

    def chore(ctx, target)
      raise "chore needs a chore name (target)" if target.blank?

      name = ctx.resolve_chore(target)&.name || target
      Resolved.new(
        scope:      "chore_completion",
        match:      { "action" => "completed", "chore_name" => name },
        human:      "next time you finish #{name}",
        owner:      ctx.user,
        place_name: name,
      )
    end

    def event(ctx, target)
      raise "event needs an event name (target)" if target.blank?

      Resolved.new(
        scope:      "event",
        match:      { "action" => "added", "name" => target },
        human:      "next time you log #{target}",
        owner:      ctx.user,
        place_name: target,
      )
    end

    def agenda(ctx, target)
      raise "agenda needs a calendar name (target)" if target.blank?

      found = ctx.resolve_writable_agenda(target)
      raise "not sure which calendar #{target} is" if found.nil?

      Resolved.new(
        scope:      "agenda_item",
        match:      { "action" => "created", "agenda_id" => found.id },
        human:      "when something's added to #{found.name}",
        owner:      found.user,
        place_name: found.name,
      )
    end

    # Whisper's day, as the five ActionEvent notes `Whisper Timers` (task 224)
    # branches on. Anyone in the house can ask about the dog, but her events are
    # the OWNER's rows, so a watch filed under whoever asked can never fire -
    # see `agenda` above for the same shape and the same fix.
    #
    # She gets a named trigger rather than a hand-written listener for two
    # reasons. `custom` files under `ctx.user` with no way to say otherwise, so
    # the honest version of this can't be expressed there at all. And the named
    # `event` trigger matches on the event NAME, which for her is "Whisper" for
    # every one of them - a watch on that fires on pees, poops, walks, baths and
    # dinners alike. The state lives in the notes.
    WHISPER_STATES = {
      "up"      => { notes: "Up",    human: "when Whisper wakes up" },
      "nap"     => { notes: "Nap",   human: "when Whisper goes down for a nap" },
      "bedtime" => { notes: "Sleep", human: "when Whisper goes down for the night" },
      "home"    => { notes: "Home",  human: "when Whisper gets home" },
      "out"     => { notes: "Gone",  human: "when Whisper leaves the house" },
    }.freeze

    # The words that mean BOTH, which have to be asked about rather than
    # resolved. Every one of these is said about two in the afternoon at least
    # as often as it's said at nine at night - "let me know when she goes to
    # bed" is usually the nap - so mapping them onto either one produces a watch
    # that fires at the wrong end of the day, or eight hours late, and from
    # outside that is indistinguishable from a dog who simply didn't go to
    # sleep.
    #
    # Only words that can ONLY be the night get an alias below. Everything about
    # sleeping in general lands here.
    WHISPER_AMBIGUOUS = [
      "down",
      "goes down",
      "go down",
      "puts her down",
      "put down",
      "sleep",
      "sleeps",
      "sleeping",
      "asleep",
      "goes to sleep",
      "go to sleep",
      "bed",
      "goes to bed",
      "go to bed",
      "settle",
      "settles",
      "settled",
    ].freeze

    # What people actually say, mapped onto those - only where it can mean one
    # thing. See WHISPER_AMBIGUOUS for the ones that can't.
    WHISPER_ALIASES = {
      "up"      => ["wake", "wakes", "wakes up", "wake up", "gets up", "awake", "waking"],
      "nap"     => ["naps", "napping", "nap time", "naptime"],
      "bedtime" => ["night", "the night", "for the night", "down for the night", "tonight", "overnight"],
      "home"    => ["gets home", "comes home", "back", "arrives"],
      "out"     => ["gone", "leaves", "goes out", "away"],
    }.freeze

    def whisper(ctx, target)
      owner = ::User.me
      raise "Whisper isn't set up here" if owner.nil?
      raise "Whisper isn't in your house" unless owner_household?(ctx.user, owner)

      # A state named outright wins: `nap` and `bedtime` are the answers the
      # ambiguity check below asks for, so they must always resolve.
      key   = target.to_s.downcase.strip
      state = WHISPER_STATES[key] || begin
        if WHISPER_AMBIGUOUS.include?(key)
          raise "#{target.inspect} is her nap as often as it's her bedtime - people usually " \
                "mean the NAP, but not always. Ask which they meant, then pass `nap` or " \
                "`bedtime`. Never pick one silently."
        end

        WHISPER_STATES[WHISPER_ALIASES.find { |_state, words| words.include?(key) }&.first]
      end
      raise "#{target.inspect} isn't one of Whisper's: #{WHISPER_STATES.keys.join(", ")}" if state.nil?

      Resolved.new(
        scope:      "event",
        match:      { "action" => "added", "name" => "Whisper", "notes" => state[:notes] },
        human:      state[:human],
        owner:      owner,
        place_name: "Whisper",
      )
    end

    def owner_household?(user, owner)
      return true if user.id == owner.id

      owner.chore_household_id.present? && user.chore_household_id == owner.chore_household_id
    end

    def deploy(ctx)
      # Phrased without "next" so the repeating form reads "every time a deploy
      # finishes" rather than "every time the NEXT deploy finishes".
      Resolved.new(scope: "deploy", match: {}, human: "when a deploy finishes", owner: ctx.user)
    end

    def custom(ctx, payload)
      listener = payload[:listener].to_s.strip
      raise "custom needs a `listener` - read read_listener_guide first" if listener.blank?

      validate_listener!(ctx, listener)

      # The person reads the plain phrasing; the listener rides underneath as
      # detail. Showing them the raw syntax as the whole description tells them
      # nothing they asked about, but dropping it entirely makes an unexpected
      # fire unexplainable.
      phrase = payload[:when_phrase].to_s.strip
      raise "custom needs a `when_phrase` saying what that listener means in their words" if phrase.blank?

      Resolved.new(
        scope:    ::Jil::ListenerMatch.scope_of(listener),
        match:    {},
        listener: listener,
        human:    phrase.sub(/\A(when|whenever)\s+/i, "when "),
        owner:    ctx.user,
      )
    end

    def validate_listener!(ctx, listener)
      unless ::Jil::ListenerMatch.valid?(listener, user: ctx.user)
        named = ::Jil::ListenerMatch.scope_of(listener)
        raise(
          if named && !::Jil::ListenerMatch.known_scope?(named, user: ctx.user)
            "nothing here has ever fired a #{named.inspect} trigger, so that listener could " \
              "never fire - call read_listener_guide and use a scope off the real list"
          else
            "#{listener.inspect} isn't a listener that could ever fire"
          end,
        )
      end

      # Valid shape, real scope, and still pointed at nothing. A watch that
      # names a list nobody has fails by being silent forever while they think
      # it's set, so it's refused here rather than saved (prod: a daily
      # flower-bed check watching a list that never existed).
      return unless (gap = Buddy::ListenerTargets.missing(listener, user: ctx.user))

      raise "#{gap}, so that watch could never fire - if they wanted something on a CLOCK " \
            "(\"daily\", \"every morning\"), that's a recurring agenda task, not a watch"
    end

    # "when you get to Costco" → "every time you get to Costco".
    def repeating_phrase(human)
      human.sub(/\Awhen /, "every time ").sub(/\Anext time /, "every time ")
    end
  end
end
