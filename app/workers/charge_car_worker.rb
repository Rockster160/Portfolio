class ChargeCarWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    Venmo.charge('8013497798', -185, "🚙")
  end
end
