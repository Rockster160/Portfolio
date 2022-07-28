class RefreshNestMessageWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    SmsWorker.perform_async(Jarvis::MY_NUMBER, "Time to refresh Nest: #{GoogleNestControl.code_url}")
  end
end
