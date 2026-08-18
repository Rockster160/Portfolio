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
  # Don't retarget a car that's already going somewhere. For SCHEDULED
  # navigation only — a calendar trigger firing mid-drive would otherwise
  # replace the destination the person is currently following. A nav they
  # asked for by name ("take me to…") leaves this off and overrides freely.
  def keepRoute(b)     = { keepRoute: b }
  # Override the line the wrapper says. When title is present, Tesla.start
  # says `title` + optional `body` instead of the default `Climate on · …`
  # bits assembly. Lets callers craft context-rich announcements (e.g. Task
  # 390 "Starting Car - Leave in 10m…").
  def title(text)      = { title: text }
  def body(text)       = { body: text }
  # Suppress the wrapper's announcement entirely — used for shared-calendar
  # events where the user is a guest and shouldn't get car-start chatter.
  # Silent still runs the actual car commands.
  def silent(b)        = { silent: b }
end
