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
  # Override the notification the wrapper emits. When title is present,
  # Tesla.start uses `title` + optional `body` instead of the default
  # `Climate on · …` bits assembly. Lets callers craft context-rich
  # notifications (e.g. Task 390 "Starting Car - Leave in 10m…").
  def title(text)      = { title: text }
  def body(text)       = { body: text }
  # Suppress the wrapper notification entirely — used for shared-calendar
  # events where the user is a guest and shouldn't get a car-start toast.
  # Silent still runs the actual car commands.
  def silent(b)        = { silent: b }
end
