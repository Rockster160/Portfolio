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
end
