class Jil::Methods::Tesla < Jil::Methods::Base
  # All methods return Boolean (success/failure). Calls funnel through
  # TeslaControl which enforces the User.me restriction at construction —
  # we also guard up-front so a non-me Jil task can't even queue the call.
  # Schema entries live in `app/service/jil/schema.txt` under [Tesla] and
  # [TeslaStartOptions].
  #
  # Every method that sends a command to the car says so (via `announce`).
  # The car can act on commands silently — without the line the user has no
  # audit trail of what Jil/Jarvis/automation just did.
  #
  # That line is a Jarvis say rather than a push. A push is an interruption,
  # and a car command is rarely one: it's either something the person just
  # asked for out loud, or automation doing its job. The messages that DO
  # warrant reaching them — leave-by, heavy traffic, time to go — now come
  # from Buddy instead (see Jil::Methods::Buddy#sayEvent), addressed to
  # whoever the event actually belongs to.

  def cast(value)
    @jil.cast(value, :Boolean)
  end

  # Tesla.start({ ... }) — Climate on, plus any optional setup specified in
  # the content block: target temp, navigate destination, heated seats,
  # vented windows, defrost. Empty content block (or no content) is fine:
  # just starts climate.
  def start(option_blocks=nil)
    wrap {
      opts = Array.wrap(option_blocks).reduce({}) { |acc, h| acc.merge(h.to_h) }.symbolize_keys
      dest = opts[:navigate].presence&.to_s

      if dest && ::TripState.car_at?(dest, user: @jil.user)
        announce("Already at destination", dest) unless opts[:silent]
        next
      end

      if dest && ::TripState.car_navigating_to?(dest, user: @jil.user)
        announce("Already navigating there", dest) unless opts[:silent]
        next
      end

      # A scheduled navigation yields to a live route. The car takes ONE
      # destination, so a calendar trigger firing mid-drive doesn't add a
      # stop — it replaces where the person is going, silently, while they're
      # following it. `keepRoute` is what separates that from a nav the person
      # just asked for by name, which should absolutely retarget the car.
      if dest && opts[:keepRoute] && ::TripState.car_routing?(user: @jil.user)
        announce("Already on a route", "left it alone rather than rerouting to #{dest}") unless opts[:silent]
        next
      end

      ctrl = ::TeslaControl.me
      ctrl.start_car
      ctrl.set_temp(opts[:temp].to_f)         if opts[:temp].present?
      ctrl.navigate(dest)                     if dest
      ctrl.heat_driver                        if opts[:heatDriver]
      ctrl.heat_passenger                     if opts[:heatPassenger]
      ctrl.windows(:open)                     if opts[:vent]
      ctrl.defrost(true)                      if opts[:defrost]

      next if opts[:silent]

      if opts[:title].present?
        announce(opts[:title].to_s, opts[:body].to_s.presence)
      else
        bits = []
        bits << "#{opts[:temp].to_i}°F" if opts[:temp].present?
        bits << "heading to #{opts[:navigate]}" if opts[:navigate].present?
        bits << "driver seat"               if opts[:heatDriver]
        bits << "passenger seat"            if opts[:heatPassenger]
        bits << "vent"                      if opts[:vent]
        bits << "defrost"                   if opts[:defrost]
        announce("Climate on", bits.join(" · ").presence)
      end
    }
  end

  def stop
    wrap {
      ::TeslaControl.me.off_car
      announce("Climate off")
    }
  end

  def honk
    wrap {
      ::TeslaControl.me.honk
      announce("Honking")
    }
  end

  def flashLights
    wrap {
      ::TeslaControl.me.send(:proxy_command, :flash_lights)
      announce("Flashing lights")
    }
  end

  def setTemp(f)
    wrap {
      ::TeslaControl.me.set_temp(f.to_f)
      announce("Temperature set to: #{f.to_i}°F")
    }
  end

  # Smart resolution — same priority as Jarvis voice nav:
  # contact name > "lat,lng" > raw address string.
  #
  # No-op (with a "Already at …" toast) when the car is already parked
  # at the requested destination — pushing a nav command in that state
  # is confusing and wakes the car for nothing. Same guard for a trip
  # already routing to that destination, so an automation re-firing
  # mid-drive doesn't wake the car to nav to where it's already going.
  def navigate(input)
    wrap {
      dest = input.to_s
      if ::TripState.car_at?(dest, user: @jil.user)
        announce("Already at destination", dest)
        next
      end
      if ::TripState.car_navigating_to?(dest, user: @jil.user)
        announce("Already navigating there", dest)
        next
      end
      ::TeslaControl.me.navigate(dest)
      # Auto-arm trip stepping when this destination matches the first
      # leg of an upcoming event. No-op when no candidate is found or a
      # trip is already in flight — see TripState.start_for_destination!.
      ::TripState.start_for_destination!(dest, @jil.user)
      announce("Navigating to #{dest}", travel_time_body(dest))
    }
  end

  # Insert a stop into the active trip. Defaults to order:1 (first waypoint
  # after the current destination). Surfaces TeslaControl#add_stop's own
  # boolean (false on bad address / geocoding miss) — unlike #wrap which
  # collapses everything to true unless an exception fires.
  def addStop(input)
    return false unless @jil.user&.me?

    dest = input.to_s
    result = ::TeslaControl.me.add_stop(dest)
    announce(result ? "Stop added" : "Couldn't add stop", dest)
    result
  rescue ::TeslaNotAuthorized
    false
  rescue StandardError => e
    ::PrettyLogger.error("[JIL TESLA] #{e.class}: #{e.message}")
    false
  end

  def lockDoors
    wrap {
      ::TeslaControl.me.doors(:close)
      announce("Doors locked")
    }
  end

  def unlockDoors
    wrap {
      ::TeslaControl.me.doors(:open)
      announce("Doors unlocked")
    }
  end

  def closeWindows
    wrap {
      ::TeslaControl.me.windows(:close)
      announce("Windows closed")
    }
  end

  def ventWindows
    wrap {
      ::TeslaControl.me.windows(:open)
      announce("Windows vented")
    }
  end

  def popFrunk
    wrap {
      ::TeslaControl.me.pop_frunk
      announce("Frunk open")
    }
  end

  def popTrunk
    wrap {
      ::TeslaControl.me.pop_boot
      announce("Trunk open")
    }
  end

  def defrost
    wrap {
      ::TeslaControl.me.defrost(true)
      announce("Defrost on")
    }
  end

  def heatDriver
    wrap {
      ::TeslaControl.me.heat_driver
      announce("Driver seat heat on")
    }
  end

  def heatPassenger
    wrap {
      ::TeslaControl.me.heat_passenger
      announce("Passenger seat heat on")
    }
  end

  # Is the car currently at `destination`? Wraps `TripState.car_at?` so
  # Jil tasks can gate on car location (e.g. only fire an automation when
  # the car is at a specific contact). Same ~500m threshold as the
  # nav/start "already there" skip. Returns false silently on any error
  # so a bad geocode doesn't blow up the task.
  def isAt(input)
    return false unless @jil.user

    ::TripState.car_at?(input.to_s, user: @jil.user)
  rescue StandardError => e
    ::PrettyLogger.error("[JIL TESLA] isAt: #{e.class}: #{e.message}")
    false
  end

  private

  # Second half of the line for a nav command — the drive time, or nil when
  # we can't get one (announce drops a blank half). Best-effort: the car
  # already has the command by the time this runs, so a Google miss or an
  # unresolvable destination costs the travel time rather than failing the
  # whole call through #wrap.
  def travel_time_body(dest)
    seconds = @jil.user&.address_book&.traveltime_seconds(dest)
    return if seconds.blank?

    "TT: #{::ActionController::Base.helpers.distance_of_time_in_words(seconds)}"
  rescue StandardError => e
    ::PrettyLogger.error("[JIL TESLA] travel_time_body: #{e.class}: #{e.message}")
    nil
  end

  # `Jarvis.say` — out over the websocket to the Jarvis cell on the dashboard,
  # with no push. #wrap has already refused anyone but me by the time this is
  # reached, which is why it can address `User.me` without asking.
  def announce(title, body=nil)
    return unless @jil.user

    ::Jarvis.say([title, body.presence].compact.join(" — "))
  rescue StandardError => e
    ::PrettyLogger.error("[JIL TESLA] announce: #{e.class}: #{e.message}")
  end

  def wrap(&block)
    return false unless @jil.user&.me?

    if ::TeslaSwitch.disabled?
      ::TeslaSwitch.maybe_remind_muted!(:jil_methods_tesla)
      return false
    end

    block.call
    true
  rescue ::TeslaNotAuthorized
    false
  rescue StandardError => e
    ::PrettyLogger.error("[JIL TESLA] #{e.class}: #{e.message}")
    false
  end
end
