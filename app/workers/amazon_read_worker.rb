# Asks the Mini to read Amazon orders: the ones named, and every order still on
# the way, so each read brings everything up to date (AmazonOrderRead). Every
# Amazon email enqueues one, and it runs once a day on its own for a day with
# no email.
#
# The Mini may be restarting, so it's tried again a little later, twice, and
# then left for the next email.
class AmazonReadWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  TRIES = 3

  def perform(order_ids=[], attempt=1)
    AmazonOrder.reload
    ids = (Array(order_ids) + AmazonOrder.open_order_ids).uniq
    return if ids.empty?
    return if ByteLocal.amazon_read(ids)
    return if attempt >= TRIES

    self.class.perform_in(30.seconds, order_ids, attempt + 1)
  end
end
