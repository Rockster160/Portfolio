module Buddy
  # The 3D printer's job log, reconstructed from ActionEvents.
  #
  # Nothing stores a print as a single row. OctoPrint's webhooks land as two
  # events per run — a `PrintStart` carrying the file's name in `notes`, then a
  # `PrintFinish` or `PrintFailed` pointing back at it through
  # `data.start_event_id` — so this pairs them up and reads the outcome off the
  # second one.
  #
  # Grouped by NAME rather than listed run by run, because the name is the
  # handle: it's what the printer knows the file by, and starting one again
  # means handing that name to the reprint function. Five copies of
  # `game_tray-vase` in a row would bury the print they actually meant.
  module PrintHistory
    module_function

    OUTCOMES = { start: :PrintStart, finished: :PrintFinish, failed: :PrintFailed }.freeze

    DEFAULT_DAYS = 60
    MAX_DAYS     = 730
    LIMIT        = 12

    # A start with no ending is only "still printing" for so long. Past its own
    # estimate plus this much slack, the run didn't finish, we just never heard
    # why — a missed webhook or a printer that lost power. Saying so is better
    # than reporting a print that's been running for three days.
    STALE_AFTER = 1.hour

    def call(user:, query: nil, days: DEFAULT_DAYS, limit: LIMIT)
      runs = runs_for(user, days)
      runs = narrow(runs, query)
      by_name = runs.group_by { |run| run[:name] }

      by_name.first(limit).map { |name, all| line(name, all, user) }
    end

    # Every run in the window, newest first.
    def runs_for(user, days)
      window = days.to_i.clamp(1, MAX_DAYS).days.ago
      events = user.action_events
        .where(name: OUTCOMES.values.map(&:to_s), timestamp: window..)
        .order(timestamp: :asc)
        .to_a
      starts, endings = events.partition { |event| outcome_of(event) == :start }
      # An ending in the window can point back at a start that predates it, and
      # a start can outlive the window on the other side. Indexing by the id the
      # ending names keeps both halves matched by identity rather than by order.
      paired = endings.index_by { |event| event.data.to_h["start_event_id"].to_i }

      starts.reverse.map { |start| run(start, paired[start.id]) }
    end

    def narrow(runs, query)
      needle = query.to_s.strip.downcase
      return runs if needle.blank?

      runs.select { |run| run[:name].downcase.include?(needle) }
    end

    def run(start, ending)
      data = start.data.to_h
      {
        name:      start.notes.to_s.strip.presence || "unnamed print",
        started:   start.timestamp,
        ended:     ending&.timestamp,
        outcome:   outcome_of(ending) || pending_outcome(start, data),
        seconds:   elapsed(ending, data),
        remaining: remaining(start, data),
        reason:    failure_reason(ending),
        filament:  data["filament_name"].to_s.strip.presence,
      }
    end

    def outcome_of(event)
      return nil if event.nil?

      OUTCOMES.key(event.name.to_s.to_sym)
    end

    def pending_outcome(start, data)
      estimate = data["estimated_seconds"].to_f
      start.timestamp + estimate.seconds + STALE_AFTER < Time.current ? :unknown : :running
    end

    def elapsed(ending, start_data)
      return start_data["estimated_seconds"] if ending.nil?

      data = ending.data.to_h
      data["actual_seconds"] || data["actual_duration"] || data["elapsed_seconds"]
    end

    # What's left of a live print. "How much longer" is the question anyone asks
    # about the one that's still running, and it's arithmetic the model
    # shouldn't have to do against a raw estimate and a start time.
    def remaining(start, data)
      estimate = data["estimated_seconds"].to_f
      return nil unless estimate.positive?

      [estimate - (Time.current - start.timestamp), 0].max
    end

    # `reason` is the webhook topic ("Print Failed" / "Print Cancelled"), which
    # is the only thing separating a crash from someone stopping it on purpose.
    def failure_reason(ending)
      return nil if ending.nil?

      data = ending.data.to_h
      data["error"].to_s.strip.presence || data["reason"].to_s.strip.presence
    end

    def line(name, runs, user)
      latest = runs.first
      [
        name,
        outcome_phrase(latest, user),
        latest[:filament],
        runs.many? ? "#{runs.length} runs" : nil,
      ].compact.join(" · ")
    end

    # A finished run is stamped by when it FINISHED - "finished 6am" against the
    # time it started is a small lie that reads perfectly plausible. Only a run
    # with no ending is described by its start.
    def outcome_phrase(run, user)
      began = Buddy::EventSearch.when_phrase(run[:started], user)
      at    = run[:ended] ? Buddy::EventSearch.when_phrase(run[:ended], user) : began
      took  = duration(run[:seconds])
      case run[:outcome]
      when :finished then "finished #{at}#{" after #{took}" if took}"
      when :failed   then "#{failed_verb(run)} #{at}#{" after #{took}" if took}#{failure_note(run)}"
      when :running  then "started #{began}, still going#{live_progress(run)}"
      else                "started #{began}, never logged a finish"
      end
    end

    def live_progress(run)
      left = duration(run[:remaining])
      return "" if left.nil?

      " - about #{left} left"
    end

    def failed_verb(run)
      run[:reason].to_s.match?(/cancel/i) ? "cancelled" : "failed"
    end

    def failure_note(run)
      reason = run[:reason]
      return "" if reason.blank? || reason.match?(/\APrint (Failed|Cancelled)\z/i)

      " (#{reason.truncate(60)})"
    end

    def duration(seconds)
      secs = seconds.to_i
      return nil unless secs.positive?

      hours, rest = secs.divmod(3600)
      mins = rest / 60
      return "#{hours}h #{mins}m" if hours.positive?
      return "#{mins}m" if mins.positive?

      "#{secs}s"
    end

    # The Jil function that puts a file back on the printer, if this person has
    # one. Looked up rather than named, so the seed can only ever point at a
    # function that really exists on their list.
    def reprint_function(user)
      return nil unless user.respond_to?(:accessible_tasks)

      user.accessible_tasks.buddy_visible.functions.detect { |task|
        task.name.to_s.match?(/re-?print|print again/i)
      }
    rescue StandardError => e
      Rails.logger.warn("[Buddy::PrintHistory] reprint lookup failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
