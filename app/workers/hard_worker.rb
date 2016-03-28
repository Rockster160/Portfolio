class HardWorker
  include Sidekiq::Worker

  def perform
    Rails.Logger.warn "\e[31m Hello Rocco! This has been a successful test of the HardWorker scheduled job. \e[0m"
  end

end
