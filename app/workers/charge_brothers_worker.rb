class ChargeBrothersWorker
  include Sidekiq::Worker

  def perform
    Venmo.charge('8018089455', -60, "👧 🚙")
    Venmo.charge('8017924442', -60, "👧 🚙")
    Venmo.charge('8016041947', -60, "👧 🚙")    
  end

end
