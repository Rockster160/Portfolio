class ReloadTeslaLocalWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    puts "[\e[33m#{Time.current.to_formatted_s(:short_with_time)}\e[0m] \e[36mTriggering Tesla Reload!\e[0m"
    TeslaControl.local
  end
end
