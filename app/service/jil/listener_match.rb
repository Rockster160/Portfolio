class Jil
  # Does this listener string match this trigger?
  #
  # Extracted from Task#match_run so Buddy watches can be written in the SAME
  # syntax as the 70-odd Jil tasks already running, and matched by the same
  # code. Two implementations of "does `item:list:name:Claude` match this
  # payload" would drift, and the one that drifted would be the one nobody
  # notices - a watch that quietly stops firing.
  #
  # The syntax is documented in docs/jil_listener_syntax.md, which is also what
  # Buddy reads before writing one.
  module ListenerMatch
    module_function

    # Every scope the app itself triggers. A listener naming anything else can
    # never fire, so this is what stops Buddy inventing one and handing back a
    # watch that sits there forever.
    #
    # Kept honest by spec/service/jil/listener_match_scopes_spec.rb, which greps
    # the app for `Jil.trigger` / `jil_trigger` calls and fails if one isn't
    # listed.
    #
    # This is HALF the picture - see `wired_scopes` for the other half.
    #
    # `travel` is announced by a Jil task rather than app code, and `deploy` is
    # the monitor broadcast Buddy::WatchMatcher reads as a finished deploy; a
    # named watch listens on both, whoever's account it's on.
    KNOWN_SCOPES = %w[
      agenda_event
      agenda_item
      agenda_schedule
      agenda_sync
      bowling
      chore
      chore_completion
      chore_transfer
      chore_withdrawal
      climbing
      delivery
      deploy
      email
      event
      item
      jarvis_subscribed
      list
      monitor
      prompt
      relay
      schedule
      section
      sms
      startup
      task
      tell
      tesla
      tesla_charge
      tesla_drive_start
      tesla_drive_stop
      tesla_parked
      tesla_shift
      tesla_trip_ended
      tesla_trip_started
      tesla_trip_updated
      travel
      trytravel
      websocket
    ].freeze

    # A listener answers to exactly one scope: the first term, up to its first
    # colon. `item:list:name:Claude` listens on `item`, and so does
    # `item list:name:Claude`.
    def scope_of(listener)
      listener.to_s.strip.downcase.split(/[\s:]/).first.presence
    end

    # Anything OUTSIDE the app can trigger a scope too. `/jil/webhook` and
    # `/jil/trigger/:trigger` take the scope straight off the request, so Home
    # Assistant posts `hass-sensor`, `hass-button`, `hass-alert`; a camera or
    # any other integration names whatever it likes. None of those appear as a
    # literal anywhere in app code, so KNOWN_SCOPES structurally cannot list
    # them - and it refused all nine of the HASS scopes this install's 28 house
    # tasks run on, which is how "let me know when someone rings the doorbell"
    # came back as "I don't have that wired".
    #
    # A task the person already has listening on a scope is the evidence
    # instead: nobody wires a task to a scope that never fires. That's a
    # stronger test than a hand-kept list, and it needs no maintenance when
    # they add a new sensor.
    WIRED_CACHE_TTL = 10.minutes

    def known_scope?(scope, user: nil)
      scope = scope.to_s.downcase
      return true if KNOWN_SCOPES.include?(scope)

      user.present? && wired_scopes(user).include?(scope)
    end

    # Scopes with a real, running task listening on them, for this person or
    # shared to them. Cached: this is read while validating a listener, not on
    # the trigger hot path, so a 10-minute lag only means a sensor wired up
    # minutes ago isn't watchable quite yet.
    def wired_scopes(user)
      return [] if user.nil?

      Rails.cache.fetch("jil:wired_scopes:#{user.id}", expires_in: WIRED_CACHE_TTL) {
        listeners = user.accessible_tasks.active.enabled.where.not(listener: [nil, ""]).pluck(:listener)
        listeners.reject { |l| l.to_s.match?(/\Afunction\(/i) }.filter_map { |l| scope_of(l) }.uniq.sort
      }
    rescue StandardError => e
      Rails.logger.warn("[ListenerMatch] wired_scopes failed: #{e.class}: #{e.message}")
      []
    end

    # A listener is a whitespace-separated set of terms that must ALL match
    # ("email:from:hunter body:challenge"), tokenized so a quoted term with a
    # space in it stays one term. A bare `NOT` folds into the term after it, so
    # `NOT departed::Home` and `-departed::Home` are the same term.
    def terms(listener)
      Tokenizer.split(listener).slice_after { |term| !term.casecmp?("NOT") }.map { |group|
        group.length > 1 ? "-#{group.last}" : group.first
      }
    end

    # A leading `-` or `!` EXCLUDES: the listener only matches an event the rest
    # of the term does not. Checked here, around the whole term, because the
    # tokenizer reads a leading `-` per value - "some value in the payload isn't
    # this one" - which is true of nearly every payload, home included.
    NEGATED_RX = /\A[-!](?=[^\s!-])/

    def negated?(term)
      term.to_s.match?(NEGATED_RX)
    end

    def positive(term)
      negated?(term) ? term.to_s[1..] : term.to_s
    end

    # The values an event must carry to match: the right-hand side of each
    # exact (`::`) term that isn't excluded. `name::Coffee` requires "Coffee";
    # `-name::Coffee`, a regex or a contains-match doesn't pin one.
    def required_values(listener)
      terms(listener).reject { |term| negated?(term) || function_call(term) }.filter_map { |term|
        value = term.to_s.split("::", 2)[1]
        value && ::Tokenizing::Breaker.unwrap(value.strip).presence
      }
    end

    # Terms that COMPUTE rather than compare, written `name(args)` and
    # optionally under a key path (`phone:near(...)`). Each returns true, false,
    # or nil when the payload doesn't carry what it needs - and nil never
    # matches, excluded or not, since "can't tell" is not "somewhere else".
    #
    # New ones go here; Jil::ListenerFunctions holds them.
    FUNCTION_RX = /\A(?:(?<path>[\w-]+(?::[\w-]+)*):)?(?<name>[a-z_]+)\((?<args>[^()]*)\)\z/i

    def function_call(term)
      found = FUNCTION_RX.match(positive(term))
      return nil if found.nil?

      fn = ::Jil::ListenerFunctions[found[:name]]
      fn && { fn: fn, path: found[:path].to_s.split(":"), args: found[:args] }
    end

    # True when every term matches. `first_match` (out-param style, matching
    # Task#match_run's needs) captures the first matching Matcher so the caller
    # can read regex captures off it.
    #
    # `data` is the RAW trigger payload; serialization happens here so callers
    # can't disagree about the shape the matcher sees.
    def call(listener, scope, data, serialized: nil)
      matched, _first = match_with_captures(listener, scope, data, serialized: serialized)
      matched
    end

    # Returns [matched, first_matching_matcher]. Task needs the matcher to pass
    # `match_data` (regex captures, match_list) into the execution.
    def match_with_captures(listener, scope, data, serialized: nil)
      return [false, nil] unless scope_of(listener) == scope.to_s.downcase

      payload = serialized || ::Tokenizing::TriggerData.serialize(data, use_global_id: false)
      first   = nil

      matched = terms(listener).all? { |term|
        next true if term == scope.to_s

        hit = term_hit(positive(term), scope, data, payload)
        next false if hit.nil?
        next !hit if negated?(term)

        first ||= hit if hit.is_a?(::Tokenizing::Matcher)
        hit.present?
      }

      [matched, first]
    end

    # True/false, nil when the term can't be answered from this payload, or
    # the Matcher itself when it matched (Task reads captures off it).
    def term_hit(term, scope, data, payload)
      if (call = function_call(term))
        path = call[:path]
        path = path.drop(1) if path.first.to_s.casecmp?(scope.to_s)
        node = data.respond_to?(:with_indifferent_access) ? data.with_indifferent_access : {}
        node = node.dig(*path) if path.any?
        return call[:fn].call(call[:args], node.respond_to?(:with_indifferent_access) ? node.with_indifferent_access : {})
      end

      # A monitor listener names a channel rather than a payload key, so it's
      # matched against the channel directly instead of the stream.
      if scope.to_s == "monitor" && data.is_a?(::Hash) && data[:channel].present?
        return true if term.match?(/\A\s*monitor::?#{Regexp.escape(data[:channel].to_s)}\s*\z/)
      end

      matcher = ::Tokenizing::Matcher.new(term, { scope => payload })
      matcher.match? ? matcher : false
    end

    # Whether a string could ever match anything: it names a scope something
    # really triggers, and the tokenizer can split it without blowing up.
    #
    # `user` widens the scope check to everything they have a task listening on
    # - pass it wherever you have one, or an integration-fed scope gets refused.
    #
    # What this can NOT tell you is whether the KEYS exist in that scope's
    # payload - `item:sparkle:yes` is perfectly valid and will never fire. No
    # static check can catch that, which is why the tool that writes these is
    # told to read real listeners off the person's own tasks first rather than
    # guessing at key names.
    def valid?(listener, user: nil)
      scope = scope_of(listener)
      return false if scope.blank? || !known_scope?(scope, user: user)

      terms(listener).any?
    rescue StandardError
      false
    end

    # A key path written with dots instead of colons. Keys are compared against
    # the segments of a payload path, so `list.name` is one key by that name and
    # equals none of them - the listener parses, names a real scope, names real
    # fields, and can never match.
    #
    # It is worth its own check because the notation arrives from somewhere that
    # looks authoritative: Buddy::TriggerShapes reports fields in DotHash form,
    # which is what a field list is keyed by. That list renders colons now, so
    # this is the net rather than the fix - and it is needed because the failure
    # is silent. A watch with a dead listener saves, reads as set, and looks
    # exactly like one whose condition simply hasn't happened yet.
    #
    # Only KEY positions are checked. A dot is ordinary in a VALUE - a domain, a
    # street address, a decimal - and a term with nothing under it is a value.
    DOTTED_KEY_RX = /\A[a-z0-9_-]+(?:\.[a-z0-9_-]+)+\z/i

    # A sentence saying why this listener can never fire, or nil. The companion
    # to Buddy::ListenerTargets.missing, which answers the same question about
    # the things a listener NAMES rather than the way it is written.
    def fault(listener)
      terms(listener).filter_map { |term| function_fault(term) || dotted_key(term) }.first
    rescue StandardError => e
      Rails.logger.warn("[ListenerMatch] fault check failed: #{e.class}: #{e.message}")
      nil
    end

    def function_fault(term)
      call = function_call(term)
      call && call[:fn].fault(call[:args])
    end

    def dotted_key(term)
      return nil if function_call(term)

      key = key_names(::Tokenizing::Breaker.call(positive(term))).find { |name| name.match?(DOTTED_KEY_RX) }
      return nil if key.nil?

      "`#{key}` separates its keys with dots, and a listener uses colons - write " \
        "`#{key.tr(".", ":")}`. A payload field list shows paths, not listener syntax."
    end

    # Every name a broken-down term uses as a KEY. A key with nothing under it
    # is a bare value being matched anywhere in the payload, not a key.
    def key_names(broken, out=[])
      return out unless broken.is_a?(::Hash)

      broken[:keys]&.each { |name, under|
        next if under.blank?

        out << name.to_s
        under.each_value { |vals| ::Array.wrap(vals).each { |val| key_names(val, out) } }
      }
      broken[:vals]&.each_value { |vals| ::Array.wrap(vals).each { |val| key_names(val, out) } }
      out
    end
  end
end
