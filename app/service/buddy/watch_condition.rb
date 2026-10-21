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
      :scope, :listener, :human, :past, :owner, :place_known, :place_name,
      keyword_init: true
    )

    TRIGGERS = %i[arrive depart travel chore event agenda whisper deploy custom].freeze

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

    # The same condition read as something that HAS NOW HAPPENED.
    #
    # Third sense of one phrase, and the one that had no form. "when the print
    # finishes" was being interpolated straight into the sentence announcing the
    # thing was over: *"when the print finishes - I've stopped the check-ins."*
    # - a condition standing where a past-tense subject belongs.
    #
    # Written out per trigger rather than conjugated, because conjugating is
    # where this would start being wrong: "the timer goes off" has no regular
    # past, and a briefing that says "the timer goed off" is worse than one that
    # says nothing. Every built-in already hand-writes its present phrase a line
    # above, so the past one is the same work and is always right; `custom` is
    # the only free-form case and the model writes both (`past_phrase`).
    #
    # nil is a legitimate answer - the caller has a neutral sentence for it.
    def past_phrase(watch)
      text = watch.metadata.to_h["human_past"].to_s.strip if watch.respond_to?(:metadata)
      text.presence
    end

    # Raises with a sentence the model can act on when the condition can't be
    # resolved - every raise here reaches the person as Buddy explaining what it
    # needs, so they read as questions rather than error text.
    #
    # Every trigger resolves to a Jil listener, matched by the same code a Jil
    # task is. A named trigger is only a shorthand for writing one: `except`
    # is that trigger's own narrowing term, negated, so "anywhere but home" and
    # "any chore but the dishes" are the same rule and neither is a special case.
    def resolve(payload, ctx)
      trigger = payload[:trigger].to_s
      target  = payload[:target].to_s.strip
      except  = payload[:except].to_s.strip

      return narrowed(ctx, trigger, target, except) if NARROWED.key?(trigger.to_sym)
      raise "`except` only narrows #{NARROWED.keys.join("/")}" if except.present?

      case trigger
      when "agenda"  then agenda(ctx, target)
      when "travel"  then travel(ctx, target)
      when "whisper" then whisper(ctx, target)
      when "deploy"  then deploy(ctx)
      when "custom"  then custom(ctx, payload)
      else raise "unknown trigger #{trigger.inspect}"
      end
    end

    # The triggers a name narrows: the scope and terms every firing carries,
    # what a name resolves to (`term`), and how each reads - for one thing,
    # and for anything but one.
    NARROWED = {
      arrive: {
        listener:  "travel:action::arrived",
        term:      :place_term,
        needs:     "a place",
        human:     "when you get to %s",
        past:      "You got to %s",
        human_any: "when you get anywhere but %s",
        past_any:  "You got somewhere other than %s",
      },
      depart: {
        listener:  "travel:action::departed",
        term:      :place_term,
        needs:     "a place",
        human:     "when you leave %s",
        past:      "You left %s",
        human_any: "when you leave anywhere but %s",
        past_any:  "You left somewhere other than %s",
      },
      chore:  {
        listener:  "chore_completion:action::completed",
        term:      :chore_term,
        needs:     "a chore name",
        human:     "next time you finish %s",
        past:      "You finished %s",
        human_any: "next time you finish a chore other than %s",
        past_any:  "You finished a chore other than %s",
      },
      event:  {
        listener:  "event:action::added",
        term:      :event_term,
        needs:     "an event name",
        human:     "next time you log %s",
        past:      "You logged %s",
        human_any: "next time you log anything but %s",
        past_any:  "You logged something other than %s",
      },
    }.freeze

    # Said when a place-shaped trigger is set with no place. "Every time I arrive
    # or leave anywhere" is a real request with no place in it, and the answer
    # is a different call, not a question back to the person.
    ANYWHERE = " - for EVERY arrival or departure anywhere, it's trigger \"travel\" instead; " \
               "don't ask them for a place".freeze

    def narrowed(ctx, trigger, target, except)
      shape = NARROWED.fetch(trigger.to_sym)
      anywhere = shape[:term] == :place_term ? ANYWHERE : ""
      raise "#{trigger} needs #{shape[:needs]} (target)#{anywhere}" if target.blank? && except.blank?

      want = target.present? ? send(shape[:term], ctx, target) : nil
      skip = except.present? ? send(shape[:term], ctx, except, excluding: true) : nil
      name = want ? want[:name] : skip[:name]
      key  = want ? :human : :human_any
      human = shape[key].sub("%s", name)
      human = "#{human}, except #{skip[:name]}" if want && skip

      Resolved.new(
        scope:       ::Jil::ListenerMatch.scope_of(shape[:listener]),
        listener:    [shape[:listener], want&.dig(:term), skip && "-#{skip[:term]}"].compact.join(" "),
        human:       human,
        past:        shape[want ? :past : :past_any].sub("%s", name),
        owner:       ctx.user,
        place_known: [want, skip].compact.all? { |part| part.fetch(:known, true) },
        place_name:  name,
      )
    end

    # How far "anywhere but" a place reaches. Wider than arriving there: the car
    # reports leaving home from past the home boundary, so the exclusion has to
    # keep holding for a departure a few hundred metres up the street.
    EXCLUDE_RADIUS_M = 550

    # A place by its coordinates, so a renamed place or a second contact at the
    # same address still matches. A contact with no coordinates is still known
    # by name, and the arrival trigger names the same contact.
    def place_term(ctx, name, excluding: false)
      resolved = ctx.resolve_place_location(name)
      place    = resolved["name"].presence || name
      loc      = Array(resolved["loc"]).map(&:to_f)
      term     = (
        if loc.length == 2 && loc.all?(&:nonzero?)
          ::Jil::ListenerFunctions::Near.term(loc, excluding ? EXCLUDE_RADIUS_M : ::Jil::ListenerFunctions::Near::NEAR_DEFAULT_M)
        else
          exact_term(:location, place)
        end
      )
      { term: term, name: place, known: resolved["known"] != false }
    end

    def chore_term(ctx, name, **)
      chore = ctx.resolve_chore(name)&.name || name
      { term: exact_term(:chore_name, chore), name: chore }
    end

    def event_term(_ctx, name, **)
      { term: exact_term(:name, name), name: name }
    end

    # `key::value`, quoted when the value has a space in it. Exact, because a
    # contains-match would let "uncompleted" satisfy a "completed" watch.
    def exact_term(key, value)
      value = value.to_s.delete("\"").strip
      "#{key}::#{value.match?(/[\s()]/) ? "\"#{value}\"" : value}"
    end

    def agenda(ctx, target)
      raise "agenda needs a calendar name (target)" if target.blank?

      # `strict`, or the raise below is unreachable: the loose form answers with
      # the default calendar for any name it doesn't know, so "watch Dinners"
      # would quietly start watching whichever calendar happened to be first.
      found = ctx.resolve_writable_agenda(target, strict: true)
      raise "not sure which calendar #{target} is" if found.nil?

      Resolved.new(
        scope:      "agenda_item",
        listener:   "agenda_item:action::created agenda_id::#{found.id}",
        human:      "when something's added to #{found.name}",
        past:       "Something was added to #{found.name}",
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
      "up"      => { notes: "Up",    human: "when Whisper wakes up",             past: "Whisper woke up" },
      "nap"     => { notes: "Nap",   human: "when Whisper goes down for a nap",  past: "Whisper went down for a nap" },
      "bedtime" => { notes: "Sleep", human: "when Whisper goes down for the night", past: "Whisper went down for the night" },
      "home"    => { notes: "Home",  human: "when Whisper gets home",            past: "Whisper got home" },
      "out"     => { notes: "Gone",  human: "when Whisper leaves the house",     past: "Whisper left the house" },
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
        listener:   "event:action::added name::Whisper #{exact_term(:notes, state[:notes])}",
        human:      state[:human],
        past:       state[:past],
        owner:      owner,
        place_name: "Whisper",
      )
    end

    def owner_household?(user, owner)
      return true if user.id == owner.id

      owner.chore_household_id.present? && user.chore_household_id == owner.chore_household_id
    end

    # Every arrival and departure, anywhere, by whichever of them they named.
    # The phone is the person and the car is the car (see TravelResolver); a
    # watch naming the car hears its reports too (Buddy::WatchMatcher).
    TRAVEL_SOURCES = {
      "phone" => { term: "source::phone",            who: "your phone" },
      "car"   => { term: "source::tesla",            who: "the car" },
      "both"  => { term: "source::OR(phone tesla)",  who: "your phone or the car" },
    }.freeze

    def travel(ctx, target)
      key = target.downcase.presence || "both"
      key = "car" if key.match?(/car|tesla/) && !key.match?(/phone|both/)
      key = "phone" if key.match?(/phone/) && !key.match?(/car|tesla|both/)
      source = TRAVEL_SOURCES[key]
      raise "travel's target is \"phone\", \"car\" or \"both\" - got #{target.inspect}" if source.nil?

      Resolved.new(
        scope:    "travel",
        listener: "travel #{source[:term]}",
        human:    "when #{source[:who]} arrives or leaves anywhere",
        past:     "#{source[:who].capitalize} arrived or left",
        owner:    ctx.user,
      )
    end

    def deploy(ctx)
      # Phrased without "next" so the repeating form reads "every time a deploy
      # finishes" rather than "every time the NEXT deploy finishes".
      Resolved.new(
        scope: "deploy", listener: "deploy", human: "when a deploy finishes",
        past: "A deploy finished", owner: ctx.user
      )
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
        listener: listener,
        human:    phrase.sub(/\A(when|whenever)\s+/i, "when "),
        past:     payload[:past_phrase].to_s.strip.presence,
        owner:    ctx.user,
      )
    end

    def validate_listener!(ctx, listener)
      # A notation fault before the generic shape check: both produce a listener
      # that never fires, and only one of them can be described.
      if (fault = ::Jil::ListenerMatch.fault(listener))
        raise "#{fault} That watch could never fire as written."
      end

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
