class ReloadTeslaLocalWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    TeslaControl.local
  end
end
