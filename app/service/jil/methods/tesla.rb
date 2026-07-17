class Jil::Methods::Tesla < Jil::Methods::Base
  # All methods return Boolean (success/failure). Calls funnel through
  # TeslaControl which enforces the User.me restriction at construction —
  # we also guard up-front so a non-me Jil task can't even queue the call.
  # Schema entries live in `app/service/jil/schema.txt` under [Tesla] and
  # [TeslaStartOptions].
  #
  # Every method that sends a command to the car pairs the broadcast with a
  # user-facing PushNotification (via `notify_user`). The car can act on
  # commands silently — without the notification the user has no audit
  # trail of what Jil/Jarvis/automation just did. Notifications are tagged
  # `:tesla_action` so they consolidate (each new toast replaces the prior).

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
        notify_user("Already at destination", dest) unless opts[:silent]
        next
      end

      if dest && ::TripState.car_navigating_to?(dest, user: @jil.user)
        notify_user("Already navigating there", dest) unless opts[:silent]
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
        notify_user(opts[:title].to_s, opts[:body].to_s.presence)
      else
        bits = []
        bits << "#{opts[:temp].to_i}°F" if opts[:temp].present?
        bits << "heading to #{opts[:navigate]}" if opts[:navigate].present?
        bits << "driver seat"               if opts[:heatDriver]
        bits << "passenger seat"            if opts[:heatPassenger]
        bits << "vent"                      if opts[:vent]
        bits << "defrost"                   if opts[:defrost]
        notify_user("Climate on", bits.join(" · ").presence)
      end
    }
  end

  def stop
    wrap {
      ::TeslaControl.me.off_car
      notify_user("Climate off")
    }
  end

  def honk
    wrap {
      ::TeslaControl.me.honk
      notify_user("Honking")
    }
  end

  def flashLights
    wrap {
      ::TeslaControl.me.send(:proxy_command, :flash_lights)
      notify_user("Flashing lights")
    }
  end

  def setTemp(f)
    wrap {
      ::TeslaControl.me.set_temp(f.to_f)
      notify_user("Temperature set to: #{f.to_i}°F")
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
        notify_user("Already at destination", dest)
        next
      end
      if ::TripState.car_navigating_to?(dest, user: @jil.user)
        notify_user("Already navigating there", dest)
        next
      end
      ::TeslaControl.me.navigate(dest)
      # Auto-arm trip stepping when this destination matches the first
      # leg of an upcoming event. No-op when no candidate is found or a
      # trip is already in flight — see TripState.start_for_destination!.
      ::TripState.start_for_destination!(dest, @jil.user)
      notify_user("Navigating", dest)
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
    notify_user(result ? "Stop added" : "Couldn't add stop", dest)
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
      notify_user("Doors locked")
    }
  end

  def unlockDoors
    wrap {
      ::TeslaControl.me.doors(:open)
      notify_user("Doors unlocked")
    }
  end

  def closeWindows
    wrap {
      ::TeslaControl.me.windows(:close)
      notify_user("Windows closed")
    }
  end

  def ventWindows
    wrap {
      ::TeslaControl.me.windows(:open)
      notify_user("Windows vented")
    }
  end

  def popFrunk
    wrap {
      ::TeslaControl.me.pop_frunk
      notify_user("Frunk open")
    }
  end

  def popTrunk
    wrap {
      ::TeslaControl.me.pop_boot
      notify_user("Trunk open")
    }
  end

  def defrost
    wrap {
      ::TeslaControl.me.defrost(true)
      notify_user("Defrost on")
    }
  end

  def heatDriver
    wrap {
      ::TeslaControl.me.heat_driver
      notify_user("Driver seat heat on")
    }
  end

  def heatPassenger
    wrap {
      ::TeslaControl.me.heat_passenger
      notify_user("Passenger seat heat on")
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

  def notify_user(title, body=nil)
    return unless @jil.user

    payload = { title: title, tag: :tesla_action }
    payload[:body] = body if body.present?
    # Explicit `channel:` so the call is unambiguous as
    # `send_to(user, payload, channel: …)` — Ruby 3 + rspec-mocks partial
    # doubles otherwise misread the 2-arg form as kwargs.
    ::WebPushNotifications.send_to(@jil.user, payload, channel: :jarvis)
  rescue StandardError => e
    ::PrettyLogger.error("[JIL TESLA] notify_user: #{e.class}: #{e.message}")
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
