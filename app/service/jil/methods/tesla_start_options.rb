class Jil::Methods::TeslaStartOptions < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
  end

  def temp(f)          = { temp: f }
  def navigate(text)   = { navigate: text }
  def heatDriver(b)    = { heatDriver: b }
  def heatPassenger(b) = { heatPassenger: b }
  def vent(b)          = { vent: b }
  def defrost(b)       = { defrost: b }

  # Multi-stop trip via N navigation_gps_request calls. Pass an array of
  # hashes with at least `lat` and `lng` per stop; `name` is optional.
  # Tesla composes them into a single trip. Coexists with `navigate` —
  # if both are present, waypoints win (a multi-stop nav overwrites a
  # single-destination nav anyway).
  def waypoints(arr)   = { waypoints: arr }
end
