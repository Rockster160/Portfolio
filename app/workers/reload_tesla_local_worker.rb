class ReloadTeslaLocalWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    Time.use_zone(User.timezone) {
      now = Time.current.to_formatted_s(:short_with_time)
      puts "[\e[33m#{now}\e[0m] \e[36mTriggering Tesla Reload!\e[0m"
    }
    TeslaControl.local
  end
end
