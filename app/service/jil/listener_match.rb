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
    KNOWN_SCOPES = %w[
      agenda_item
      agenda_schedule
      agenda_sync
      bowling
      chore
      chore_completion
      chore_transfer
      chore_withdrawal
      climbing
      email
      event
      item
      jarvis_subscribed
      list
      monitor
      prompt
      section
      sms
      startup
      task
      tesla
      tesla_charge
      tesla_drive_start
      tesla_drive_stop
      tesla_parked
      tesla_shift
      tesla_trip_ended
      tesla_trip_started
      tesla_trip_updated
      websocket
    ].freeze

    # A listener answers to exactly one scope: the segment before the first
    # colon. `item:list:name:Claude` listens on `item`.
    def scope_of(listener)
      listener.to_s.strip.downcase.split(":").first.presence
    end

    # Anything OUTSIDE the app can trigger a scope too. `/jil/webhook` and
    # `/jil/trigger/:trigger` take the scope straight off the request, so Home
    # Assistant posts `hass-sensor`, `hass-button`, `hass-alert`; a camera or
    # any other integration names whatever it likes. None of those appear as a
    # literal anywhere in app code, so KNOWN_SCOPES structurally cannot list
    # them - and it refused all nine of the HASS scopes this install's 28 house
    # tasks run on, which is how "let me know when someone rings the doorbell"
    # came back as "I don't have that wired" (prod 1479-1482).
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
    # space in it stays one term.
    def terms(listener)
      Tokenizer.split(listener)
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

        # A monitor listener names a channel rather than a payload key, so it's
        # matched against the channel directly instead of the stream.
        if scope.to_s == "monitor" && data.is_a?(::Hash) && data[:channel].present?
          next true if term.match?(/\A\s*monitor::?#{Regexp.escape(data[:channel].to_s)}\s*\z/)
        end

        matcher = ::Tokenizing::Matcher.new(term, { scope => payload })
        matcher.match?.tap { |m| first ||= matcher if m }
      }

      [matched, first]
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
  end
end
