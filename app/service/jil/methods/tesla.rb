class Jil::Methods::Tesla < Jil::Methods::Base
  # All methods return Boolean (success/failure). Calls funnel through
  # TeslaControl which enforces the User.me restriction at construction —
  # we also guard up-front so a non-me Jil task can't even queue the call.
  # Schema entries live in `app/service/jil/schema.txt` under [Tesla] and
  # [TeslaStartOptions].

  def cast(value)
    @jil.cast(value, :Boolean)
  end

  # Tesla.start({ ... }) — Climate on, plus any optional setup specified in
  # the content block: target temp, navigate destination, heated seats,
  # vented windows, defrost. Empty content block (or no content) is fine:
  # just starts climate.
  #
  # Content keys (see [TeslaStartOptions] in schema):
  #   temp:           Numeric (°F)
  #   navigate:       Text  (contact name, address, or "lat,lng")
  #   heatDriver:     Boolean
  #   heatPassenger:  Boolean
  #   vent:           Boolean  (vent windows)
  #   defrost:        Boolean
  def start(option_blocks=nil)
    wrap {
      ctrl = ::TeslaControl.me
      ctrl.start_car
      opts = Array.wrap(option_blocks).reduce({}) { |acc, h| acc.merge(h.to_h) }.symbolize_keys

      ctrl.set_temp(opts[:temp].to_f)         if opts[:temp].present?
      ctrl.heat_driver                        if opts[:heatDriver]
      ctrl.heat_passenger                     if opts[:heatPassenger]
      ctrl.windows(:open)                     if opts[:vent]
      ctrl.defrost(true)                      if opts[:defrost]
      # Trip plan beats single-destination navigate — if both are present,
      # the trip wins (a multi-stop request would otherwise be overwritten
      # by the single navigate immediately).
      if opts[:waypoints].present?
        ctrl.navigate_trip(opts[:waypoints])
      elsif opts[:navigate].present?
        ctrl.navigate(opts[:navigate].to_s)
      end
    }
  end

  def stop          = wrap { ::TeslaControl.me.off_car }
  def honk          = wrap { ::TeslaControl.me.honk }
  def flashLights   = wrap { ::TeslaControl.me.send(:proxy_command, :flash_lights) }
  def setTemp(f)    = wrap { ::TeslaControl.me.set_temp(f.to_f) }

  # Smart resolution — same priority as Jarvis voice nav:
  # contact name > "lat,lng" > raw address string.
  def navigate(input) = wrap { ::TeslaControl.me.navigate(input.to_s) }

  def lockDoors     = wrap { ::TeslaControl.me.doors(:close) }
  def unlockDoors   = wrap { ::TeslaControl.me.doors(:open) }
  def closeWindows  = wrap { ::TeslaControl.me.windows(:close) }
  def ventWindows   = wrap { ::TeslaControl.me.windows(:open) }
  def popFrunk      = wrap { ::TeslaControl.me.pop_frunk }
  def popTrunk      = wrap { ::TeslaControl.me.pop_boot }
  def defrost       = wrap { ::TeslaControl.me.defrost(true) }
  def heatDriver    = wrap { ::TeslaControl.me.heat_driver }
  def heatPassenger = wrap { ::TeslaControl.me.heat_passenger }

  private

  def wrap(&block)
    return false unless @jil.user&.me?

    block.call
    true
  rescue ::TeslaNotAuthorized
    false
  rescue StandardError => e
    ::PrettyLogger.error("[JIL TESLA] #{e.class}: #{e.message}")
    false
  end
end
