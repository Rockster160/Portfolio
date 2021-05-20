class HourlyVenmoCheckWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    VenmoRecurring.active.now.find_each do |venmo_charge|
      venmo_charge.charge
    end
  end
end
