class ReloadTeslaLocalWorker
  include Sidekiq::Worker
  sidekiq_options retry: false
  queue_as :local_tesla

  def perform
    Time.use_zone(User.timezone) {
      now = Time.current.strftime("%-m/%-d/%y %l:%M %p")
      puts "[\e[33m#{now}\e[0m] \e[36mTriggering Tesla Reload!\e[0m"
    }
    TeslaControl.local
  end
end
