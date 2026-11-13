# What the Mini read off Amazon's order pages, applied (AmazonOrderRead). Its
# own job because naming new products is a model call, and the Mini's request
# shouldn't wait on it.
class AmazonReadResultWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 2

  def perform(payload)
    AmazonOrderRead.apply!(payload)
  end
end
