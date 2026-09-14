# Reconciles one person's "Chores" list against the chores that are actually
# due. Off the request thread because it walks every chore they can see, and
# because the thing that triggered it — a tap, a tick, the 4am rollover — has
# no reason to wait for a list to be redrawn.
class ChoreListSyncWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 2

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil?

    ChoreListSync.push(user)
  end
end
