# After a deploy (Sidekiq's startup hook, once the new app is up): marks the
# merges it brought in as live, and lets the merge queue hand out its next
# turn. A site still waking up gets a few more tries, a minute apart.
class MergeQueueDeployedWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  TRIES = 3

  def perform(attempt=1)
    waiting = MergeQueue.deployed!
    self.class.perform_in(1.minute, attempt + 1) if waiting && attempt < TRIES
  end
end
