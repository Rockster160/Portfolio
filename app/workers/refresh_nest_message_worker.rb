class RefreshNestMessageWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    SmsWorker.perform_async(Jarvis::MY_NUMBER, "Time to refresh Nest: #{GoogleNestControl.code_url}")
    # Add to TODO
    ::User.first.lists.ilike(name: "Todo").take.list_items.by_name_then_update(name: "Refresh Nest")
  end
end
